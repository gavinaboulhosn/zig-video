const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");

const pool = @import("pool.zig");
const PacketPool = pool.PacketPool;
const FramePool = pool.FramePool;

pub const PixelFormat = enum {
    RGB24,
    YUV420P,
    // Similar to above, but full range (0-255) instead of 16-235
    YUVJ420P,
};

pub const VideoFrame = struct {
    allocator: Allocator,
    width: c_int,
    height: c_int,
    format: PixelFormat,
    data: []u8,
    linesize: c_int,
    pts: i64,

    pub fn deinit(self: *VideoFrame) void {
        self.allocator.free(self.data);
    }
};

pub const AudioFrame = struct {
    num_channels: usize,
    sample_rate: usize,
    num_samples: usize,
    sample_size: usize,
    data: std.ArrayList([]const u8),
    is_planar: bool,

    pub fn deinit(self: *AudioFrame) void {
        self.data.deinit();
    }
};

pub const Frame = union(enum) {
    video: VideoFrame,
    audio: AudioFrame,

    pub fn deinit(self: *Frame) void {
        switch (self.*) {
            .video => |*v| v.deinit(),
            .audio => |*a| a.deinit(),
        }
    }
};

pub const Decoder = struct {
    allocator: Allocator,
    format_context: ?*c.AVFormatContext = null,
    codec_contexts: std.ArrayList(*c.AVCodecContext),
    sws_context: ?*c.SwsContext = null,
    video_stream_index: c_int,
    audio_stream_index: c_int,
    packet_pool: PacketPool,
    frame_pool: FramePool,

    const Self = @This();

    pub fn init(allocator: Allocator, path: [:0]const u8) !Self {
        var self = Self{
            .allocator = allocator,
            .codec_contexts = std.ArrayList(*c.AVCodecContext).init(allocator),
            .packet_pool = try PacketPool.init(allocator, 100),
            .frame_pool = try FramePool.init(allocator, 100),
            .video_stream_index = -1,
            .audio_stream_index = -1,
        };

        try self.openFile(path);
        try self.findStreams();
        try self.openCodecs();
        try self.setupConverter();

        return self;
    }

    pub fn deinit(self: *Self) void {
        c.avformat_close_input(@ptrCast(&self.format_context));
        for (self.codec_contexts.items) |*codec_context| {
            c.avcodec_free_context(@ptrCast(codec_context));
        }
        self.codec_contexts.deinit();
        c.sws_freeContext(self.sws_context);
        self.packet_pool.deinit();
        self.frame_pool.deinit();
    }

    pub fn readPacket(self: *Self) !?*c.AVPacket {
        const packet = self.packet_pool.acquire() orelse return error.PacketPoolExhausted;

        const ret = c.av_read_frame(self.format_context, packet);

        if (ret == c.AVERROR_EOF) {
            std.debug.print("End of file\n", .{});
            return null;
        } else if (ret < 0) {
            return error.PacketReadFailed;
        }

        return packet;
    }

    pub fn decodePacket(self: *Self, packet: *c.AVPacket) !?*c.AVFrame {
        const codec_context = try self.getCodecContext(packet.stream_index);

        if (c.avcodec_send_packet(codec_context, packet) < 0) {
            return error.PacketDecodeFailed;
        }

        const frame = self.frame_pool.acquire() orelse return error.FramePoolExhausted;
        errdefer self.frame_pool.release(frame) catch {
            std.debug.print("Failed to release frame\n", .{});
        };

        const ret = c.avcodec_receive_frame(codec_context, frame);
        if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF) {
            std.debug.print("No frame to decode\n", .{});
            return null;
        } else if (ret < 0) {
            return error.PacketDecodeFailed;
        }

        return frame;
    }

    pub fn decodeNextFrame(self: *Self) !?Frame {
        while (true) {
            const packet = try self.readPacket() orelse {
                std.debug.print("No more packets ", .{});
                break;
            };
            defer self.packet_pool.release(packet) catch {
                std.debug.print("Failed to release packet\n", .{});
            };

            const frame = try self.decodePacket(packet) orelse continue;
            defer self.frame_pool.release(frame) catch {
                std.debug.print("Failed to release frame\n", .{});
            };

            if (packet.stream_index == self.video_stream_index) {
                std.debug.print("Processing video frame\n", .{});
                if (try self.processVideoFrame(frame)) |video_frame| {
                    return .{ .video = video_frame };
                }
            } else if (packet.stream_index == self.audio_stream_index) {
                std.debug.print("Processing audio frame\n", .{});
                if (try self.processAudioFrame(frame)) |audio_frame| {
                    return .{ .audio = audio_frame };
                }
            }
        }
        return null;
    }

    fn processAudioFrame(self: *Self, frame: *c.AVFrame) !?AudioFrame {
        const num_samples: usize = @intCast(frame.nb_samples);
        const codec_context = try self.getCodecContext(self.audio_stream_index);
        const num_channels: usize = @intCast(codec_context.ch_layout.nb_channels);
        const bytes_per_sample: usize = @intCast(c.av_get_bytes_per_sample(codec_context.sample_fmt));

        const is_planar = c.av_sample_fmt_is_planar(codec_context.sample_fmt) != 0;

        var data = std.ArrayList([]const u8).init(self.allocator);

        for (0..num_channels) |i| {
            const channel_data = frame.data[i];
            try data.append(channel_data[0 .. num_samples * bytes_per_sample]);
        }

        return AudioFrame{
            .num_channels = @intCast(codec_context.ch_layout.nb_channels),
            .sample_rate = @intCast(codec_context.sample_rate),
            .num_samples = @intCast(frame.nb_samples),
            .data = data,
            .is_planar = is_planar,
            .sample_size = bytes_per_sample,
        };
    }

    fn processVideoFrame(self: *Self, frame: *c.AVFrame) !?VideoFrame {
        const codec_context = try self.getCodecContext(self.video_stream_index);

        var rgb_frame = self.frame_pool.acquire() orelse return error.FramePoolExhausted;
        defer self.frame_pool.release(rgb_frame) catch {
            std.debug.print("Failed to release frame\n", .{});
        };
        const buf_size: usize = @intCast(codec_context.width * codec_context.height * 4);

        const rgb_buffer = try self.allocator.alloc(u8, buf_size);

        _ = c.av_image_fill_arrays(
            &rgb_frame.data[0],
            &rgb_frame.linesize[0],
            rgb_buffer.ptr,
            c.AV_PIX_FMT_RGB0,
            codec_context.width,
            codec_context.height,
            1,
        );

        _ = c.sws_scale(
            self.sws_context.?,
            &frame.data[0],
            &frame.linesize[0],
            0,
            codec_context.height,
            &rgb_frame.data[0],
            &rgb_frame.linesize[0],
        );

        return VideoFrame{
            .allocator = self.allocator,
            .data = rgb_buffer,
            .linesize = rgb_frame.linesize[0],
            .width = codec_context.width,
            .height = codec_context.height,
            .format = getPixelFormat(rgb_frame.format),
            .pts = rgb_frame.pts,
        };
    }

    fn getCodecContext(self: *Self, stream_index: c_int) !*c.AVCodecContext {
        if (stream_index < 0 or stream_index >= self.codec_contexts.items.len) {
            return error.InvalidStreamIndex;
        }

        return self.codec_contexts.items[@intCast(stream_index)];
    }

    fn openFile(self: *Self, path: [:0]const u8) !void {
        if (c.avformat_open_input(&self.format_context, path, null, null) < 0) {
            return error.FileOpenError;
        }

        if (c.avformat_find_stream_info(self.format_context, null) < 0) {
            return error.NoStreamInfo;
        }
    }

    fn findStreams(self: *Self) !void {
        self.video_stream_index = c.av_find_best_stream(self.format_context, c.AVMEDIA_TYPE_VIDEO, -1, -1, null, 0);
        self.audio_stream_index = c.av_find_best_stream(self.format_context, c.AVMEDIA_TYPE_AUDIO, -1, -1, null, 0);

        if (self.video_stream_index < 0) {
            return error.NoVideoStreamFound;
        }

        if (self.audio_stream_index < 0) {
            return error.NoAudioStreamFound;
        }
    }

    fn openCodecs(self: *Self) !void {
        for (0..self.format_context.?.nb_streams) |i| {
            const codec = c.avcodec_find_decoder(self.format_context.?.streams[i].*.codecpar.*.codec_id) orelse return error.OpenCodecError;
            var codec_context = c.avcodec_alloc_context3(codec);
            errdefer c.avcodec_free_context(&codec_context);

            if (c.avcodec_parameters_to_context(codec_context, self.format_context.?.streams[i].*.codecpar) < 0) {
                return error.OpenCodecError;
            }

            if (c.avcodec_open2(codec_context, codec, null) < 0) {
                return error.OpenCodecError;
            }

            try self.codec_contexts.append(codec_context);
        }
    }

    fn setupConverter(self: *Self) !void {
        const video_codec_context = try self.getCodecContext(self.video_stream_index);

        self.sws_context = c.sws_getContext(
            video_codec_context.width,
            video_codec_context.height,
            video_codec_context.pix_fmt,
            video_codec_context.width,
            video_codec_context.height,
            c.AV_PIX_FMT_RGB0,
            c.SWS_BILINEAR,
            null,
            null,
            null,
        ) orelse return error.SwsContextCreationFailed;
    }
};

fn getPixelFormat(pix_fmt: c.AVPixelFormat) PixelFormat {
    return switch (pix_fmt) {
        c.AV_PIX_FMT_YUV420P => PixelFormat.YUV420P,
        c.AV_PIX_FMT_RGB24 => PixelFormat.RGB24,
        c.AV_PIX_FMT_YUVJ420P => PixelFormat.YUVJ420P,
        else => PixelFormat.RGB24,
    };
}
