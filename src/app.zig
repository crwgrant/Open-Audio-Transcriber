const std = @import("std");

const config = @import("config.zig");
const audio_estimate = @import("audio_estimate.zig");
const io_util = @import("io_util.zig");
const log = @import("log.zig");
const models = @import("models.zig");
const perf_profile = @import("perf_profile.zig");
const runtime = @import("runtime.zig");
const transcribe = @import("transcribe.zig");

pub const Status = enum {
    idle,
    loading_models,
    ready,
    transcribing,
    done,
    error_state,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    status: Status = .idle,
    status_message: []const u8 = "Ready",
    discovered: std.ArrayList(models.AsrModel) = .empty,
    selected_index: ?usize = null,
    custom_model_path: []const u8 = "",
    custom_mmproj_path: []const u8 = "",
    audio_path: []const u8 = "",
    audio_estimate: ?audio_estimate.Estimate = null,
    output_path: []const u8 = "",
    process_log: log.Buffer,
    runtimes: []runtime.Option = &.{},
    selected_runtime: runtime.Id = .cpu,
    rtf_profile: perf_profile.Profile = .{},
    worker: ?std.Thread = null,
    worker_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_mutex: std.Io.Mutex = std.Io.Mutex.init,
    pending_result: ?WorkerResult = null,
    worker_err: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{
            .allocator = allocator,
            .process_log = log.Buffer.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.waitForWorker();
        self.freeDiscovered();
        runtime.freeOptions(self.allocator, self.runtimes);
        self.process_log.deinit();
        if (self.custom_model_path.len > 0) self.allocator.free(self.custom_model_path);
        if (self.custom_mmproj_path.len > 0) self.allocator.free(self.custom_mmproj_path);
        if (self.audio_path.len > 0) self.allocator.free(self.audio_path);
        if (self.audio_estimate) |*est| est.deinit(self.allocator);
        if (self.output_path.len > 0) self.allocator.free(self.output_path);
        if (self.worker_err) |e| self.allocator.free(e);
    }

    pub fn bootstrap(self: *App) !void {
        self.setStatus(.loading_models, "Scanning for ASR models...");
        self.freeDiscovered();
        runtime.freeOptions(self.allocator, self.runtimes);
        self.runtimes = try runtime.discover(self.allocator);
        self.selected_runtime = self.runtimes[0].id;

        self.discovered = try models.discover(self.allocator, .{});
        self.selected_index = null;

        if (models.findDefault(self.discovered.items, self.allocator)) |idx| {
            self.selected_index = idx;
        } else if (self.discovered.items.len > 0) {
            self.selected_index = 0;
        }

        var saved_runtime: ?runtime.Id = null;
        if (try config.load(self.allocator)) |saved| {
            defer saved.deinit(self.allocator);
            if (saved.runtime) |rt| saved_runtime = rt;
            self.rtf_profile = saved.rtfProfile();
            if (models.findByModelPath(self.discovered.items, saved.model_path)) |idx| {
                self.selected_index = idx;
            } else {
                self.setCustomModel(saved.model_path, saved.mmproj_path);
            }
        } else {
            const defaults = try models.defaultModelPaths(self.allocator);
            defer self.allocator.free(defaults.model);
            defer self.allocator.free(defaults.mmproj);
            if (io_util.fileExists(defaults.model)) {
                self.setCustomModel(defaults.model, defaults.mmproj);
            }
        }

        if (saved_runtime) |rt| {
            if (runtime.findOption(self.runtimes, rt)) |_| {
                self.selected_runtime = rt;
            }
        }

        self.setStatus(.ready, "Ready");
    }

    pub fn selectRuntime(self: *App, id: runtime.Id) void {
        if (runtime.findOption(self.runtimes, id) == null) return;
        self.selected_runtime = id;
        self.refreshAudioEstimate();
    }

    pub fn selectedModel(self: *const App) ?struct { model: []const u8, mmproj: []const u8, label: []const u8 } {
        if (self.custom_model_path.len > 0 and self.custom_mmproj_path.len > 0) {
            return .{
                .model = self.custom_model_path,
                .mmproj = self.custom_mmproj_path,
                .label = std.fs.path.basename(self.custom_model_path),
            };
        }
        if (self.selected_index) |idx| {
            const m = self.discovered.items[idx];
            return .{ .model = m.model_path, .mmproj = m.mmproj_path, .label = m.label };
        }
        return null;
    }

    pub fn setCustomModel(self: *App, model_path: []const u8, mmproj_path: []const u8) void {
        const new_model = self.allocator.dupe(u8, model_path) catch return;
        const new_mmproj = self.allocator.dupe(u8, mmproj_path) catch {
            self.allocator.free(new_model);
            return;
        };
        self.allocator.free(self.custom_model_path);
        self.allocator.free(self.custom_mmproj_path);
        self.custom_model_path = new_model;
        self.custom_mmproj_path = new_mmproj;
        self.selected_index = null;
    }

    pub fn selectDiscovered(self: *App, index: usize) void {
        if (index >= self.discovered.items.len) return;
        self.selected_index = index;
        if (self.custom_model_path.len > 0) self.allocator.free(self.custom_model_path);
        if (self.custom_mmproj_path.len > 0) self.allocator.free(self.custom_mmproj_path);
        self.custom_model_path = "";
        self.custom_mmproj_path = "";
    }

    pub fn setAudioPath(self: *App, path: []const u8) !void {
        const copy = try self.allocator.dupe(u8, path);
        self.allocator.free(self.audio_path);
        self.audio_path = copy;
        self.refreshAudioEstimate();

        if (self.output_path.len == 0) {
            const stem = std.fs.path.stem(path);
            const out = try std.fmt.allocPrint(self.allocator, "{s}.txt", .{stem});
            self.allocator.free(self.output_path);
            self.output_path = out;
        }
    }

    pub fn setOutputPath(self: *App, path: []const u8) !void {
        const copy = try self.allocator.dupe(u8, path);
        self.allocator.free(self.output_path);
        self.output_path = copy;
    }

    pub fn canTranscribe(self: *const App) bool {
        return self.status != .transcribing and
            self.selectedModel() != null and
            self.audio_path.len > 0 and
            self.output_path.len > 0;
    }

    pub fn clearLog(self: *App) void {
        if (self.status == .transcribing) return;
        self.process_log.clear();
    }

    pub fn cancelTranscription(self: *App) void {
        if (self.status != .transcribing) return;
        self.cancel_requested.store(true, .release);
        self.status_message = "Cancelling...";
    }

    pub fn startTranscription(self: *App) !void {
        if (!self.canTranscribe()) return error.InvalidState;
        self.waitForWorker();

        const model = self.selectedModel().?;
        try config.save(self.allocator, .{
            .model_path = model.model,
            .mmproj_path = model.mmproj,
            .runtime = self.selected_runtime,
            .rtf_profile = self.rtf_profile,
        });

        if (self.worker_err) |e| {
            self.allocator.free(e);
            self.worker_err = null;
        }

        self.setStatus(.transcribing, "Transcribing audio...");
        self.cancel_requested.store(false, .release);
        self.process_log.appendFmt("--- Starting transcription ---", .{});

        const ctx = try self.allocator.create(WorkerContext);
        ctx.* = .{
            .app = self,
            .model_path = try self.allocator.dupeZ(u8, model.model),
            .mmproj_path = try self.allocator.dupeZ(u8, model.mmproj),
            .audio_path = try self.allocator.dupeZ(u8, self.audio_path),
            .output_path = try self.allocator.dupe(u8, self.output_path),
            .runtime = self.selected_runtime,
            .audio_duration_secs = if (self.audio_estimate) |est| est.duration_secs else null,
        };

        self.worker = try std.Thread.spawn(.{}, workerMain, .{ctx});
    }

    pub fn poll(self: *App) void {
        if (self.worker == null) return;
        if (!self.worker_done.load(.acquire)) return;
        self.finishWorker();
    }

    fn waitForWorker(self: *App) void {
        while (self.worker != null) {
            if (self.worker_done.load(.acquire)) {
                self.finishWorker();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    fn finishWorker(self: *App) void {
        const io = io_util.io();
        self.worker_mutex.lockUncancelable(io);
        const result = self.pending_result orelse {
            self.worker_mutex.unlock(io);
            return;
        };
        self.pending_result = null;
        self.worker_mutex.unlock(io);

        if (self.worker) |t| {
            t.join();
            self.worker = null;
        }
        self.worker_done.store(false, .release);
        self.onWorkerDone(result);
    }

    fn setStatus(self: *App, status: Status, message: []const u8) void {
        self.status = status;
        self.status_message = message;
    }

    fn freeDiscovered(self: *App) void {
        if (self.discovered.items.len > 0) {
            models.freeAll(self.allocator, &self.discovered);
        }
    }

    fn onWorkerDone(self: *App, result: WorkerResult) void {
        switch (result) {
            .success => |done| {
                self.allocator.free(done.text);
                if (done.audio_secs > 0.0 and done.elapsed_secs > 0.0) {
                    const rtf = done.elapsed_secs / done.audio_secs;
                    self.rtf_profile.set(self.selected_runtime, rtf);
                    self.refreshAudioEstimate();
                    var rtf_buf: [32]u8 = undefined;
                    const rtf_str = std.fmt.bufPrint(&rtf_buf, "{d:.1}x", .{rtf}) catch "—";
                    self.process_log.appendFmt("Transcription complete ({s} realtime).", .{rtf_str});
                } else {
                    self.process_log.appendFmt("Transcription complete.", .{});
                }
                self.setStatus(.done, "Transcription complete");
                self.persistConfig() catch {};
            },
            .cancelled => {
                self.process_log.appendFmt("Transcription cancelled.", .{});
                self.setStatus(.ready, "Transcription cancelled");
            },
            .failure => |err_msg| {
                if (self.worker_err) |e| self.allocator.free(e);
                self.worker_err = err_msg;
                self.process_log.appendFmt("Error: {s}", .{err_msg});
                self.setStatus(.error_state, "Transcription failed");
            },
        }
    }

    fn refreshAudioEstimate(self: *App) void {
        if (self.audio_estimate) |*est| est.deinit(self.allocator);
        self.audio_estimate = null;
        if (self.audio_path.len == 0) return;
        self.audio_estimate = audio_estimate.analyze(
            self.allocator,
            self.audio_path,
            self.selected_runtime,
            self.rtf_profile,
        ) catch null;
    }

    fn persistConfig(self: *App) !void {
        const model = self.selectedModel() orelse return;
        try config.save(self.allocator, .{
            .model_path = model.model,
            .mmproj_path = model.mmproj,
            .runtime = self.selected_runtime,
            .rtf_profile = self.rtf_profile,
        });
    }
};

const WorkerContext = struct {
    app: *App,
    model_path: [:0]u8,
    mmproj_path: [:0]u8,
    audio_path: [:0]u8,
    output_path: []u8,
    runtime: runtime.Id,
    audio_duration_secs: ?f64,
};

const WorkerResult = union(enum) {
    success: struct {
        text: []u8,
        elapsed_secs: f64,
        audio_secs: f64,
    },
    cancelled: void,
    failure: []u8,
};

fn workerMain(ctx: *WorkerContext) void {
    defer {
        ctx.app.allocator.free(ctx.model_path);
        ctx.app.allocator.free(ctx.mmproj_path);
        ctx.app.allocator.free(ctx.audio_path);
        ctx.app.allocator.free(ctx.output_path);
        ctx.app.allocator.destroy(ctx);
    }

    const result: WorkerResult = blk: {
        const io = io_util.io();
        const start = std.Io.Clock.Timestamp.now(io, .real);
        const text = transcribe.transcribe(ctx.app.allocator, .{
            .model_path = ctx.model_path,
            .mmproj_path = ctx.mmproj_path,
            .audio_path = ctx.audio_path,
            .log_buffer = &ctx.app.process_log,
            .cancel_flag = &ctx.app.cancel_requested,
            .runtime = ctx.runtime,
        }) catch |err| {
            if (err == error.Cancelled) {
                break :blk .{ .cancelled = {} };
            }
            const msg = std.fmt.allocPrint(ctx.app.allocator, "Transcription failed: {s}", .{@errorName(err)}) catch {
                break :blk .{ .failure = ctx.app.allocator.dupe(u8, "Transcription failed") catch unreachable };
            };
            break :blk .{ .failure = msg };
        };

        io_util.writeFileAbsolute(ctx.output_path, text) catch |err| {
            ctx.app.allocator.free(text);
            const msg = std.fmt.allocPrint(ctx.app.allocator, "Could not write output: {s}", .{@errorName(err)}) catch {
                break :blk .{ .failure = ctx.app.allocator.dupe(u8, "Could not write output") catch unreachable };
            };
            break :blk .{ .failure = msg };
        };

        const end = std.Io.Clock.Timestamp.now(io, .real);
        const elapsed_dur = std.Io.Timestamp.durationTo(start.raw, end.raw);
        const elapsed_secs = @as(f64, @floatFromInt(elapsed_dur.nanoseconds)) / 1e9;

        break :blk .{
            .success = .{
                .text = text,
                .elapsed_secs = elapsed_secs,
                .audio_secs = ctx.audio_duration_secs orelse 0.0,
            },
        };
    };

    const io = io_util.io();
    ctx.app.worker_mutex.lockUncancelable(io);
    ctx.app.pending_result = result;
    ctx.app.worker_mutex.unlock(io);
    ctx.app.worker_done.store(true, .release);
}
