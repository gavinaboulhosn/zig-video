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

const MAX_AUDIO_BUFFER_SIZE = 4096;

const AudioBuffer = std.fifo.LinearFifo(i16, .{ .Static = MAX_AUDIO_BUFFER_SIZE * 10 });
var audio_buffer: AudioBuffer = AudioBuffer.init();

// TODO: this is pretty much hard coded to work for 16 bit audio,
// Raylib provides a simplified audio callback api compared to miniaudio, so we can't
// pass a user data pointer to the callback, so we have to use a global variable
fn audioCallback(any_buffer: ?*anyopaque, frames: u32) callconv(.C) void {
    const buf = @as([*]i16, @ptrCast(@alignCast(any_buffer)))[0 .. frames * 2];
    _ = audio_buffer.read(buf);
}

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

        const decoder = try dec.Decoder.init(
            allocator,
            decoder_config,
            audio_queue,
            video_queue,
        );

        const renderer = Renderer.init(allocator, 800, 600, "Video Player");

        const channels = decoder_config.getAudioChannelLayout().nb_channels;

        const audio_stream = raylib.loadAudioStream(
            decoder_config.audio_sample_rate,
            decoder_config.getSampleSize() * 8,
            @intCast(channels),
        );

        raylib.setAudioStreamBufferSizeDefault(MAX_AUDIO_BUFFER_SIZE);
        raylib.setAudioStreamCallback(audio_stream, audioCallback);
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

        // Free all remaining frames.  This also wakes up the decode thread
        // if it was waiting on a conditon.
        while (self.audio_queue.peek()) |_| {
            var frame = self.audio_queue.pop() catch {};
            frame.deinit();
        }
        while (self.video_queue.peek()) |_| {
            var frame = self.video_queue.pop() catch {};
            frame.deinit();
        }

        self.decode_thread.join();
        self.decoder.deinit();
        self.renderer.deinit();
        self.audio_queue.deinit();
        self.allocator.destroy(self.audio_queue);
        self.video_queue.deinit();
        self.allocator.destroy(self.video_queue);
        raylib.unloadAudioStream(self.audio_stream);
    }

    pub fn start(self: *Self) !void {
        self.decode_thread = try std.Thread.spawn(.{}, decodeThreadFn, .{self});
    }

    pub fn update(self: *Self) !void {
        const elapsed_time = self.clock.getTime();

        if (raylib.isKeyPressed(raylib.KeyboardKey.key_space)) {
            if (raylib.isAudioStreamPlaying(self.audio_stream)) {
                raylib.pauseAudioStream(self.audio_stream);
                self.clock.pause();
            } else {
                raylib.resumeAudioStream(self.audio_stream);
                self.clock.unpause();
            }
        }

        while (self.audio_queue.peek()) |f| {
            if (f.pts > elapsed_time) {
                break;
            }
            var frame = try self.audio_queue.pop();
            defer frame.deinit();

            const buffer = std.mem.bytesAsSlice(i16, frame.raw_data);
            try audio_buffer.write(@ptrCast(@alignCast(buffer)));
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
