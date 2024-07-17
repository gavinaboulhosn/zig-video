const std = @import("std");
const Allocator = std.mem.Allocator;

const Renderer = @import("renderer.zig");
const c = @import("c.zig");

const raylib = @import("raylib");
const dec = @import("decoder.zig");
const AudioFrame = dec.AudioFrame;
const VideoFrame = dec.VideoFrame;

const Queue = @import("queue.zig").Queue;

pub const AudioQueue = Queue(AudioFrame);
pub const VideoQueue = Queue(VideoFrame);

const Clock = @import("clock.zig").Clock;

pub const Player = struct {
    allocator: Allocator,
    decoder: dec.Decoder,
    renderer: Renderer,
    clock: Clock,
    audio_queue: *AudioQueue,
    video_queue: *VideoQueue,

    audio_stream: raylib.AudioStream,

    decode_thread: std.Thread,
    is_running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: Allocator, file_path: []const u8) !Self {
        var audio_queue = try allocator.create(AudioQueue);
        errdefer audio_queue.deinit();
        audio_queue.* = try AudioQueue.init(allocator, 100);

        var video_queue = try allocator.create(VideoQueue);
        errdefer video_queue.deinit();
        video_queue.* = try VideoQueue.init(allocator, 50);

        const decoder_config = dec.Decoder.DecoderConfig{
            .file_path = file_path,
        };

        const decoder = try dec.Decoder.init(allocator, decoder_config, audio_queue, video_queue);

        const renderer = Renderer.init(allocator, 800, 600, "Video Player");

        const channels = decoder_config.getAudioChannelLayout().nb_channels;

        const audio_stream = raylib.loadAudioStream(
            decoder_config.audio_sample_rate,
            decoder_config.getSampleSize() * 8,
            @intCast(channels),
        );

        raylib.playAudioStream(audio_stream);

        const self = Self{
            .allocator = allocator,
            .decoder = decoder,
            .renderer = renderer,
            .audio_stream = audio_stream,
            .clock = Clock.init(),
            .audio_queue = audio_queue,
            .video_queue = video_queue,
            .decode_thread = undefined,
            .is_running = std.atomic.Value(bool).init(true),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.is_running.store(false, .release);
        self.decode_thread.join();
        self.decoder.deinit();
        self.renderer.deinit();
        raylib.unloadAudioStream(self.audio_stream);
        while (self.audio_queue.peek()) |_| {
            var frame = self.audio_queue.pop() catch {};
            frame.deinit();
        }
        while (self.video_queue.peek()) |_| {
            var frame = self.video_queue.pop() catch {};
            frame.deinit();
        }
        self.audio_queue.deinit();
        self.allocator.destroy(self.audio_queue);
        self.video_queue.deinit();
        self.allocator.destroy(self.video_queue);
    }

    pub fn start(self: *Self) !void {
        self.decode_thread = try std.Thread.spawn(.{}, decodeThreadFn, .{self});
    }

    pub fn update(self: *Self) !void {
        const elapsed_time = self.clock.getTime();

        while (self.audio_queue.peek()) |f| {
            if (f.pts > elapsed_time) {
                break;
            }
            var frame = try self.audio_queue.pop();
            defer frame.deinit();

            if (raylib.isAudioStreamProcessed(self.audio_stream)) {
                raylib.updateAudioStream(self.audio_stream, frame.raw_data.ptr, @intCast(frame.num_samples));
            } else {
                std.debug.print("Audio stream not processed\n", .{});
            }
        }

        while (self.video_queue.peek()) |f| {
            if (f.pts > elapsed_time) {
                break;
            }
            var frame = try self.video_queue.pop();
            defer frame.deinit();
            self.renderer.update(&frame);
        }
    }

    pub fn render(self: *Self) !void {
        try self.renderer.render();
    }

    fn decodeThreadFn(self: *Self) void {
        var decoder = self.decoder;
        while (self.is_running.load(.acquire)) {
            decoder.decodeLoop() catch |err| {
                if (err == error.EndOfFile) {
                    std.debug.print("End of file\n", .{});
                    break;
                } else {
                    std.debug.print("Error in decode loop: {}\n", .{err});
                }
            };
        }
    }
};
