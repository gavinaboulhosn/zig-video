const std = @import("std");
const Allocator = std.mem.Allocator;

const raylib = @import("raylib");
const VideoFrame = @import("decoder.zig").VideoFrame;

const Self = @This();

allocator: Allocator,
width: i32,
height: i32,
video_texture: ?raylib.Texture2D,

pub fn init(allocator: Allocator, width: i32, height: i32, title: [:0]const u8) Self {
    const self = Self{
        .allocator = allocator,
        .width = width,
        .height = height,
        .video_texture = null,
    };

    const config = raylib.ConfigFlags{
        .window_resizable = true,
    };

    raylib.initWindow(width, height, title);
    raylib.setTargetFPS(30);
    raylib.setWindowState(config);

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.video_texture) |texture| {
        raylib.unloadTexture(texture);
    }
    raylib.closeWindow();
}

pub fn shouldClose(self: *Self) bool {
    _ = self;
    return raylib.windowShouldClose();
}

pub fn update(self: *Self, frame: *const VideoFrame) void {
    if (self.video_texture == null) {
        self.video_texture = raylib.loadTextureFromImage(raylib.Image{
            .data = frame.data.ptr,
            .width = frame.width,
            .height = frame.height,
            .mipmaps = 1,
            .format = raylib.PixelFormat.pixelformat_uncompressed_r8g8b8a8,
        });
    }

    raylib.updateTexture(self.video_texture.?, frame.data.ptr);
}

pub fn render(self: *Self) !void {
    if (self.video_texture == null) {
        return;
    }
    const window_width = @as(f32, @floatFromInt(raylib.getScreenWidth()));
    const window_height = @as(f32, @floatFromInt(raylib.getScreenHeight()));
    const frame_width: f32 = @floatFromInt(self.video_texture.?.width);
    const frame_height: f32 = @floatFromInt(self.video_texture.?.height);

    const window_aspect: f32 = window_width / window_height;
    const video_aspect: f32 = frame_width / frame_height;

    var dest_width: f32 = undefined;
    var dest_height: f32 = undefined;

    if (video_aspect > window_aspect) {
        dest_width = window_width;
        dest_height = window_width / video_aspect;
    } else {
        dest_height = window_height;
        dest_width = window_height * video_aspect;
    }

    const dest_x = (window_width - dest_width) / 2;
    const dest_y = (window_height - dest_height) / 2;

    raylib.drawTexturePro(
        self.video_texture.?,
        raylib.Rectangle{
            .x = 0,
            .y = 0,
            .width = frame_width,
            .height = frame_height,
        },
        raylib.Rectangle{
            .x = dest_x,
            .y = dest_y + 36,
            .width = dest_width,
            .height = dest_height - 72,
        },
        raylib.Vector2{ .x = 0, .y = 0 },
        0,
        raylib.Color.white,
    );
}
