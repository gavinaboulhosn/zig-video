const std = @import("std");
const Allocator = std.mem.Allocator;

const raylib = @import("raylib");
const c = @import("c.zig");
const dec = @import("decoder.zig");
const Decoder = dec.Decoder;
const VideoFrame = dec.VideoFrame;

const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;

fn yuvToRGB(y: u8, u: u8, v: u8) [3]u8 {
    const c_1 = @as(i32, y) - 16;
    const d = @as(i32, u) - 128;
    const e = @as(i32, v) - 128;

    var r = (298 * c_1 + 409 * e + 128) >> 8;
    var g = (298 * c_1 - 100 * d - 208 * e + 128) >> 8;
    var b = (298 * c_1 + 516 * d + 128) >> 8;

    r = @max(0, @min(255, r));
    g = @max(0, @min(255, g));
    b = @max(0, @min(255, b));

    return .{ @intCast(r), @intCast(g), @intCast(b) };
}

fn convertYUVFrameToRGB(vframe: VideoFrame, rgb_data: []u8) void {
    const width = @as(usize, @intCast(vframe.width));
    const height = @as(usize, @intCast(vframe.height));
    const y_plane = vframe.data[0];
    const u_plane = vframe.data[1];
    const v_plane = vframe.data[2];
    const y_stride = @as(usize, @intCast(vframe.linesize[0]));
    const uv_stride = @as(usize, @intCast(vframe.linesize[1]));

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const y_index = y * y_stride + x;
            const uv_index = (y / 2) * uv_stride + (x / 2);
            const rgb = yuvToRGB(y_plane[y_index], u_plane[uv_index], v_plane[uv_index]);
            const rgb_index = (y * width + x) * 3;
            rgb_data[rgb_index] = rgb[0];
            rgb_data[rgb_index + 1] = rgb[1];
            rgb_data[rgb_index + 2] = rgb[2];
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var decoder = try Decoder.init(allocator, "./res/test.mp4");
    defer decoder.deinit();

    c.av_dump_format(decoder.format_context.?, 0, "./res/test.mp4", 0);

    raylib.initWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Zig Video Player");
    defer raylib.closeWindow();
    raylib.setTargetFPS(60);

    var texture: ?raylib.Texture2D = null;
    var rgb_data: []u8 = undefined;

    defer if (texture) |text| {
        raylib.unloadTexture(text);
    };

    var total_frames: usize = 0;
    while (!raylib.windowShouldClose()) {
        raylib.beginDrawing();
        defer raylib.endDrawing();
        raylib.clearBackground(raylib.Color.ray_white);

        if (try decoder.decodeNextFrame()) |frame| {
            switch (frame) {
                .video => |vframe| {
                    if (texture == null) {
                        rgb_data = try allocator.alloc(u8, @as(usize, @intCast(vframe.width)) * @as(usize, @intCast(vframe.height)) * 3);
                        texture = raylib.loadTextureFromImage(raylib.Image{
                            .data = rgb_data.ptr,
                            .width = vframe.width,
                            .height = vframe.height,
                            .mipmaps = 1,
                            .format = raylib.PixelFormat.pixelformat_uncompressed_r8g8b8,
                        });
                    }

                    convertYUVFrameToRGB(vframe, rgb_data);
                    raylib.updateTexture(texture.?, rgb_data.ptr);

                    const vframe_width_f32 = @as(f32, @floatFromInt(vframe.width));
                    const vframe_height_f32 = @as(f32, @floatFromInt(vframe.height));
                    const scale = @min(@as(f32, WINDOW_WIDTH) / vframe_width_f32, @as(f32, WINDOW_HEIGHT) / vframe_height_f32);
                    const dest_width = @as(i32, @intFromFloat(vframe_width_f32 * scale));
                    const dest_height = @as(i32, @intFromFloat(vframe_height_f32 * scale));
                    const dest_x = @divTrunc(WINDOW_WIDTH - dest_width, 2);
                    const dest_y = @divTrunc(WINDOW_HEIGHT - dest_height, 2);

                    raylib.drawTexturePro(
                        texture.?,
                        raylib.Rectangle{ .x = 0, .y = 0, .width = vframe_width_f32, .height = vframe_height_f32 },
                        raylib.Rectangle{ .x = @floatFromInt(dest_x), .y = @floatFromInt(dest_y), .width = @floatFromInt(dest_width), .height = @floatFromInt(dest_height) },
                        raylib.Vector2{ .x = 0, .y = 0 },
                        0,
                        raylib.Color.white,
                    );

                    total_frames += 1;
                },
            }
        } else {
            std.debug.print("Finished decoding video frames: {d}\n", .{total_frames});
            break;
        }

        raylib.drawFPS(10, 10);
    }
}
