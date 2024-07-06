const std = @import("std");
const Allocator = std.mem.Allocator;

const raylib = @import("raylib");
const c = @import("c.zig");

const Decoder = @import("decoder.zig").Decoder;
const Renderer = @import("renderer.zig");

const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var decoder = try Decoder.init(allocator, "./res/test.mp4");
    defer decoder.deinit();

    var renderer = Renderer.init(allocator, WINDOW_WIDTH, WINDOW_HEIGHT, "Zig Video Player");
    defer renderer.deinit();

    var total_frames: usize = 0;
    while (!renderer.shouldClose()) {
        if (try decoder.decodeNextFrame()) |frame| {
            switch (frame) {
                .video => |vframe| {
                    try renderer.renderVideoFrame(&vframe);
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
