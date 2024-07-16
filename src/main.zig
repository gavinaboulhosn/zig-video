const std = @import("std");
const Allocator = std.mem.Allocator;

const raylib = @import("raylib");
const c = @import("c.zig");

// const Decoder = @import("decoder.zig").Decoder;
const dec = @import("decoder.zig");
const Decoder = dec.Decoder;
const Frame = dec.Frame;
const Renderer = @import("renderer.zig");
const Player = @import("player.zig").Player;

const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    raylib.initAudioDevice();
    defer raylib.closeAudioDevice();

    var player = try Player.init(allocator, "./res/test.mp4");
    defer player.deinit();

    while (!player.renderer.shouldClose()) {
        try player.update();

        raylib.beginDrawing();
        defer raylib.endDrawing();
        raylib.clearBackground(raylib.Color.white);

        try player.render();

        raylib.drawFPS(10, 10);
    }
}
