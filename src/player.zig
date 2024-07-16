const std = @import("std");
const Allocator = std.mem.Allocator;

const Renderer = @import("renderer.zig");
const c = @import("c.zig");

const raylib = @import("raylib");
const dec = @import("decoder.zig");

pub const Clock = struct {
    start_time: f64,

    const Self = @This();

    pub fn init() Self {
        const start_time = raylib.getTime();
        return Self{ .start_time = start_time };
    }

    pub fn getElapsedTime(self: *Self) f64 {
        return raylib.getTime() - self.start_time;
    }
};

pub const Player = struct {
    allocator: Allocator,
    decoder: dec.Decoder,
    renderer: Renderer,
    clock: Clock,

    audio_stream: raylib.AudioStream,

    const Self = @This();

    pub fn init(allocator: Allocator, file_path: []const u8) !Self {
        const decoder_config = dec.Decoder.DecoderConfig{
            .file_path = file_path,
        };
        const decoder = try dec.Decoder.init(allocator, decoder_config);
        const renderer = Renderer.init(allocator, 800, 600, "Video Player");

        const channels = decoder_config.getAudioChannelLayout().nb_channels;
        const audio_stream = raylib.loadAudioStream(
            decoder_config.audio_sample_rate,
            decoder_config.getSampleSize() * 8,
            @intCast(channels),
        );

        raylib.playAudioStream(audio_stream);

        return Self{
            .allocator = allocator,
            .decoder = decoder,
            .renderer = renderer,
            .audio_stream = audio_stream,
            .clock = Clock.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.decoder.deinit();
        self.renderer.deinit();
        raylib.unloadAudioStream(self.audio_stream);
    }

    pub fn update(self: *Self) !void {
        const elapsed_time = self.clock.getElapsedTime();

        while (true) {
            var frame_opt = try self.decoder.decodeNextFrame() orelse return;
            defer frame_opt.deinit();

            const pts = frame_opt.getPts();
            if (pts > elapsed_time) {
                std.debug.print("pts: {}\nelapsed: {}", .{ pts, elapsed_time });
                break;
            }

            switch (frame_opt) {
                .video => |*frame| {
                    self.renderer.update(frame);
                },
                .audio => |*frame| {
                    if (raylib.isAudioStreamProcessed(self.audio_stream)) {
                        raylib.updateAudioStream(self.audio_stream, frame.raw_data.ptr, @intCast(frame.num_samples));
                    }
                },
            }
        }
    }

    pub fn render(self: *Self) !void {
        try self.renderer.render();
    }
};
