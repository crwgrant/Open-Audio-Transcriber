const std = @import("std");

const io_util = @import("io_util.zig");

const max_probe_bytes: usize = 65536;

pub fn probeDurationSeconds(path: []const u8) ?f64 {
    const data = io_util.readFileSmall(std.heap.page_allocator, path, max_probe_bytes) catch return null;
    defer std.heap.page_allocator.free(data);

    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".wav")) return probeWav(data);
    if (std.ascii.eqlIgnoreCase(ext, ".flac")) return probeFlac(data);
    if (std.ascii.eqlIgnoreCase(ext, ".mp3")) return probeMp3(data, path);
    return probeByMagic(data);
}

fn probeByMagic(data: []const u8) ?f64 {
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "RIFF")) return probeWav(data);
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "fLaC")) return probeFlac(data);
    if (data.len >= 3 and data[0] == 'I' and data[1] == 'D' and data[2] == '3') return probeMp3(data, "");
    if (data.len >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) return probeMp3(data, "");
    return null;
}

fn probeWav(data: []const u8) ?f64 {
    if (data.len < 44 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) {
        return null;
    }

    var offset: usize = 12;
    var sample_rate: u32 = 0;
    var byte_rate: u32 = 0;
    var data_size: u32 = 0;

    while (offset + 8 <= data.len) {
        const chunk_id = data[offset .. offset + 4];
        const chunk_size = readLeU32(data[offset + 4 .. offset + 8]);
        offset += 8;
        if (offset + chunk_size > data.len) break;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16) return null;
            sample_rate = readLeU32(data[offset + 4 .. offset + 8]);
            byte_rate = readLeU32(data[offset + 8 .. offset + 12]);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_size = chunk_size;
        }

        offset += chunk_size;
        if (chunk_size % 2 == 1) offset += 1;
    }

    if (byte_rate > 0 and data_size > 0) {
        return @as(f64, @floatFromInt(data_size)) / @as(f64, @floatFromInt(byte_rate));
    }
    if (sample_rate > 0 and data_size > 0) {
        // Assume 16-bit mono if byte_rate missing.
        const bytes_per_sample: f64 = 2.0;
        return @as(f64, @floatFromInt(data_size)) / (@as(f64, @floatFromInt(sample_rate)) * bytes_per_sample);
    }
    return null;
}

fn probeFlac(data: []const u8) ?f64 {
    if (data.len < 42 or !std.mem.eql(u8, data[0..4], "fLaC")) return null;

    var offset: usize = 4;
    while (offset + 4 <= data.len) {
        const header = data[offset];
        const block_type = header & 0x7F;
        const is_last = (header & 0x80) != 0;
        const block_len = (@as(u32, data[offset + 1]) << 16) |
            (@as(u32, data[offset + 2]) << 8) |
            @as(u32, data[offset + 3]);
        offset += 4;
        if (offset + block_len > data.len) return null;

        if (block_type == 0 and block_len >= 18) {
            const info = data[offset .. offset + block_len];
            const sample_rate = (@as(u32, info[10]) << 12) |
                (@as(u32, info[11]) << 4) |
                (@as(u32, info[12]) >> 4);
            const total_samples = (@as(u64, info[12] & 0x0F) << 32) |
                (@as(u64, info[13]) << 24) |
                (@as(u64, info[14]) << 16) |
                (@as(u64, info[15]) << 8) |
                @as(u64, info[16]);
            if (sample_rate > 0 and total_samples > 0) {
                return @as(f64, @floatFromInt(total_samples)) / @as(f64, @floatFromInt(sample_rate));
            }
            return null;
        }

        offset += block_len;
        if (is_last) break;
    }
    return null;
}

fn probeMp3(data: []const u8, path: []const u8) ?f64 {
    var offset: usize = 0;
    if (data.len >= 10 and std.mem.eql(u8, data[0..3], "ID3")) {
        const tag_size = synchsafeSize(data[6..10]);
        offset = 10 + tag_size;
    }

    if (offset >= data.len) return probeMp3FromFileSize(path);

    const slice = data[offset..];
    if (findMp3XingDuration(slice)) |secs| return secs;
    if (findMp3CbrDuration(slice, path)) |secs| return secs;
    return probeMp3FromFileSize(path);
}

fn findMp3XingDuration(data: []const u8) ?f64 {
    var i: usize = 0;
    while (i + 4 < data.len and i < 8192) : (i += 1) {
        if (data[i] != 0xFF or (data[i + 1] & 0xE0) != 0xE0) continue;
        const version = (data[i + 1] >> 3) & 0x03;
        const layer = (data[i + 1] >> 1) & 0x03;
        if (layer == 0) continue;

        const header_len: usize = if (version == 3) 4 else 6;
        if (i + header_len + 12 > data.len) continue;

        const side_info_len: usize = if (version == 3) blk: {
            const channel_mode = (data[i + 3] >> 6) & 0x03;
            break :blk if (channel_mode == 3) 17 else 32;
        } else blk: {
            const channel_mode = (data[i + 3] >> 6) & 0x03;
            break :blk if (channel_mode == 3) 9 else 17;
        };

        const xing_offset = i + header_len + side_info_len;
        if (xing_offset + 12 > data.len) continue;

        const tag = data[xing_offset .. xing_offset + 4];
        if (!std.mem.eql(u8, tag, "Xing") and !std.mem.eql(u8, tag, "Info")) continue;

        const flags = readBeU32(data[xing_offset + 4 .. xing_offset + 8]);
        if ((flags & 0x01) == 0) continue;

        const frames = readBeU32(data[xing_offset + 8 .. xing_offset + 12]);
        const sample_rate = mp3SampleRate(data[i + 2], data[i + 3]);
        if (sample_rate == 0 or frames == 0) return null;

        const samples_per_frame: f64 = if (version == 3) 1152.0 else 576.0;
        return (@as(f64, @floatFromInt(frames)) * samples_per_frame) / @as(f64, @floatFromInt(sample_rate));
    }
    return null;
}

fn findMp3CbrDuration(data: []const u8, path: []const u8) ?f64 {
    var i: usize = 0;
    while (i + 4 < data.len and i < 4096) : (i += 1) {
        if (data[i] != 0xFF or (data[i + 1] & 0xE0) != 0xE0) continue;
        const bitrate_kbps = mp3BitrateKbps(data[i + 2], data[i + 3]);
        if (bitrate_kbps == 0) continue;

        const file_size = fileSizeBytes(path) orelse return null;

        const audio_bytes = @as(f64, @floatFromInt(@max(file_size, 0)));
        const bitrate_bps = @as(f64, @floatFromInt(bitrate_kbps)) * 1000.0;
        return (audio_bytes * 8.0) / bitrate_bps;
    }
    return null;
}

fn probeMp3FromFileSize(path: []const u8) ?f64 {
    if (path.len == 0) return null;
    const file_size = fileSizeBytes(path) orelse return null;
    if (file_size <= 0) return null;
    // Rough fallback for unknown VBR mp3 without Xing header.
    const bitrate_bps: f64 = 128_000.0;
    return (@as(f64, @floatFromInt(file_size)) * 8.0) / bitrate_bps;
}

fn fileSizeBytes(path: []const u8) ?u64 {
    const file = std.Io.Dir.openFileAbsolute(io_util.io(), path, .{}) catch return null;
    defer file.close(io_util.io());
    const st = file.stat(io_util.io()) catch return null;
    return st.size;
}

fn mp3SampleRate(byte2: u8, byte3: u8) u32 {
    const version = (byte2 >> 3) & 0x03;
    const sr_index = (byte3 >> 2) & 0x03;
    if (sr_index == 3) return 0;

    return switch (version) {
        3 => switch (sr_index) {
            0 => 44100,
            1 => 48000,
            2 => 32000,
            else => 0,
        },
        2 => switch (sr_index) {
            0 => 22050,
            1 => 24000,
            2 => 16000,
            else => 0,
        },
        1 => switch (sr_index) {
            0 => 11025,
            1 => 12000,
            2 => 8000,
            else => 0,
        },
        else => 0,
    };
}

fn mp3BitrateKbps(byte2: u8, byte3: u8) u32 {
    const version = (byte2 >> 3) & 0x03;
    const layer = (byte2 >> 1) & 0x03;
    const bitrate_index = (byte3 >> 4) & 0x0F;
    if (layer != 1 or bitrate_index == 0 or bitrate_index == 15) return 0;

    const table_v1_l3 = [_]u32{
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
    };
    const table_v2_l3 = [_]u32{
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
    };

    if (version == 3) return table_v1_l3[bitrate_index];
    if (version == 2 or version == 0) return table_v2_l3[bitrate_index];
    return 0;
}

fn synchsafeSize(bytes: []const u8) usize {
    return (@as(usize, bytes[0] & 0x7F) << 21) |
        (@as(usize, bytes[1] & 0x7F) << 14) |
        (@as(usize, bytes[2] & 0x7F) << 7) |
        @as(usize, bytes[3] & 0x7F);
}

fn readLeU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readBeU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}
