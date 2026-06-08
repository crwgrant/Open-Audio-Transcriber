const std = @import("std");

const config = @import("config.zig");
const io_util = @import("io_util.zig");
const models = @import("models.zig");
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
    output_path: []const u8 = "",
    last_transcript: []const u8 = "",
    worker: ?std.Thread = null,
    worker_err: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *App) void {
        self.waitForWorker();
        self.freeDiscovered();
        if (self.custom_model_path.len > 0) self.allocator.free(self.custom_model_path);
        if (self.custom_mmproj_path.len > 0) self.allocator.free(self.custom_mmproj_path);
        if (self.audio_path.len > 0) self.allocator.free(self.audio_path);
        if (self.output_path.len > 0) self.allocator.free(self.output_path);
        if (self.last_transcript.len > 0) self.allocator.free(self.last_transcript);
        if (self.worker_err) |e| self.allocator.free(e);
    }

    pub fn bootstrap(self: *App) !void {
        self.setStatus(.loading_models, "Scanning for ASR models...");
        self.freeDiscovered();
        self.discovered = try models.discover(self.allocator, .{});
        self.selected_index = null;

        if (models.findDefault(self.discovered.items, self.allocator)) |idx| {
            self.selected_index = idx;
        } else if (self.discovered.items.len > 0) {
            self.selected_index = 0;
        }

        if (try config.load(self.allocator)) |saved| {
            defer saved.deinit(self.allocator);
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

        self.setStatus(.ready, "Ready");
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

    pub fn startTranscription(self: *App) !void {
        if (!self.canTranscribe()) return error.InvalidState;
        self.waitForWorker();

        const model = self.selectedModel().?;
        try config.save(self.allocator, model.model, model.mmproj);

        if (self.worker_err) |e| {
            self.allocator.free(e);
            self.worker_err = null;
        }

        self.setStatus(.transcribing, "Transcribing audio...");
        const ctx = try self.allocator.create(WorkerContext);
        ctx.* = .{
            .app = self,
            .model_path = try self.allocator.dupeZ(u8, model.model),
            .mmproj_path = try self.allocator.dupeZ(u8, model.mmproj),
            .audio_path = try self.allocator.dupeZ(u8, self.audio_path),
            .output_path = try self.allocator.dupe(u8, self.output_path),
        };

        self.worker = try std.Thread.spawn(.{}, workerMain, .{ctx});
    }

    pub fn poll(self: *App) void {
        self.waitForWorker();
    }

    fn waitForWorker(self: *App) void {
        if (self.worker) |t| {
            t.join();
            self.worker = null;
        }
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
            .success => |text| {
                self.allocator.free(self.last_transcript);
                self.last_transcript = text;
                self.setStatus(.done, "Transcription complete");
            },
            .failure => |err_msg| {
                if (self.worker_err) |e| self.allocator.free(e);
                self.worker_err = err_msg;
                self.setStatus(.error_state, err_msg);
            },
        }
    }
};

const WorkerContext = struct {
    app: *App,
    model_path: [:0]u8,
    mmproj_path: [:0]u8,
    audio_path: [:0]u8,
    output_path: []u8,
};

const WorkerResult = union(enum) {
    success: []u8,
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
        const text = transcribe.transcribe(ctx.app.allocator, .{
            .model_path = ctx.model_path,
            .mmproj_path = ctx.mmproj_path,
            .audio_path = ctx.audio_path,
        }) catch |err| {
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

        break :blk .{ .success = text };
    };

    ctx.app.onWorkerDone(result);
}
