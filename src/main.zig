const std = @import("std");
const Allocator = std.mem.Allocator;

const raylib = @import("raylib");
const c = @import("c.zig");

// const Decoder = @import("decoder.zig").Decoder;
const dec = @import("decoder.zig");
const Decoder = dec.Decoder;
const Frame = dec.Frame;
const Renderer = @import("renderer.zig");

const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var decoder = try Decoder.init(allocator, "./res/test.mp4");
    defer decoder.deinit();

    var renderer = Renderer.init(allocator, WINDOW_WIDTH, WINDOW_HEIGHT, "Zig Video Player");
    defer renderer.deinit();

    raylib.initAudioDevice();
    defer raylib.closeAudioDevice();

    var audio_stream: ?raylib.AudioStream = null;

    var total_video_frames: usize = 0;
    var total_audio_frames: usize = 0;

    while (!renderer.shouldClose()) {
        const frame_opt = decoder.decodeNextFrame() catch |err| {
            std.debug.print("Error decoding frame: {any}\n", .{err});
            continue;
        };
        if (frame_opt) |*frame| {
            // lul
            var frame_mut: *Frame = @ptrFromInt(@intFromPtr(frame));
            defer frame_mut.deinit();
            switch (frame.*) {
                .video => |*vframe| {
                    try renderer.renderVideoFrame(vframe);
                    total_video_frames += 1;
                },
                .audio => |*aframe| {
                    if (audio_stream == null) {
                        audio_stream = raylib.loadAudioStream(
                            @intCast(aframe.sample_rate),
                            @intCast(aframe.num_samples),
                            @intCast(aframe.num_channels),
                        );
                        raylib.playAudioStream(audio_stream.?);
                    }

                    total_audio_frames += 1;
                },
            }
        } else {
            std.debug.print("Finished decoding {d} video frames and {d} audio frames\n", .{ total_video_frames, total_audio_frames });
            break;
        }

        raylib.drawFPS(10, 10);
    }
}
