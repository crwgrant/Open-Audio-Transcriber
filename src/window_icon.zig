const std = @import("std");
const zglfw = @import("zglfw");

const c = @cImport({
    @cInclude("window_icon_stb.h");
});

const icon_32_png = @embedFile("assets/icon_32x32.png");
const icon_128_png = @embedFile("assets/icon_128x128.png");

pub const IconImage = struct {
    image: zglfw.Image,
    pixels: []u8,

    pub fn deinit(self: *IconImage, allocator: std.mem.Allocator) void {
        if (self.pixels.len == 0) return;
        allocator.free(self.pixels);
        self.pixels = &.{};
    }
};

pub const WindowIcons = struct {
    images: []IconImage,

    pub fn deinit(self: *WindowIcons, allocator: std.mem.Allocator) void {
        for (self.images) |*img| img.deinit(allocator);
        allocator.free(self.images);
        self.images = &.{};
    }
};

pub fn loadEmbeddedIcons(allocator: std.mem.Allocator) !WindowIcons {
    var images: std.ArrayList(IconImage) = .empty;
    errdefer {
        for (images.items) |*img| img.deinit(allocator);
        images.deinit(allocator);
    }

    try images.append(allocator, try decodePng(allocator, icon_32_png));
    try images.append(allocator, try decodePng(allocator, icon_128_png));

    return .{ .images = try images.toOwnedSlice(allocator) };
}

pub fn applyWindowIcons(window: *zglfw.Window, icons: *const WindowIcons) void {
    if (icons.images.len == 0) return;

    var glfw_images: [2]zglfw.Image = undefined;
    const count = @min(icons.images.len, glfw_images.len);
    for (0..count) |i| glfw_images[i] = icons.images[i].image;
    window.setIcon(glfw_images[0..count]);
}

fn decodePng(allocator: std.mem.Allocator, png: []const u8) !IconImage {
    var width: c_int = 0;
    var height: c_int = 0;
    const ptr = c.stbi_load_from_memory(
        png.ptr,
        @intCast(png.len),
        &width,
        &height,
        null,
        4,
    );
    if (ptr == null) return error.DecodeFailed;

    const pixel_count = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const pixels = allocator.alloc(u8, pixel_count) catch {
        c.stbi_image_free(ptr);
        return error.OutOfMemory;
    };
    @memcpy(pixels, ptr[0..pixel_count]);
    c.stbi_image_free(ptr);

    return .{
        .image = .{
            .width = width,
            .height = height,
            .pixels = pixels.ptr,
        },
        .pixels = pixels,
    };
}
