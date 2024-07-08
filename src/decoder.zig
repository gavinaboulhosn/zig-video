const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");

pub const PixelFormat = enum {
    RGB24,
    YUV420P,
    // Similar to above, but full range (0-255) instead of 16-235
    YUVJ420P,
};

pub const VideoFrame = struct {
    width: c_int,
    height: c_int,
    format: PixelFormat,
    data: [*]u8,
    linesize: c_int,
    pts: i64,
};

pub const AudioFrame = struct {};

pub const Frame = union(enum) {
    video: VideoFrame,
    audio: AudioFrame,
};

pub const Decoder = struct {
    allocator: Allocator,
    format_context: ?*c.AVFormatContext = null,
    video_codec_context: *c.AVCodecContext = undefined,
    video_stream_index: c_int = -1,
    video_frame: ?*c.AVFrame = null,
    video_frame_rgb: ?*c.AVFrame = null,
    packet: *c.AVPacket,
    video_buffer: []u8,
    sws_context: ?*c.SwsContext = null,
    audio_stream_index: c_int = -1,
    audio_frame: ?*c.AVFrame = null,
    audio_codec_context: *c.AVCodecContext = undefined,

    const Self = @This();

    pub fn init(allocator: Allocator, path: [:0]const u8) !Self {
        var self = Self{
            .allocator = allocator,
            .packet = c.av_packet_alloc() orelse return error.BuyMoreRam,
            .video_buffer = undefined,
            .video_frame = c.av_frame_alloc() orelse return error.BuyMoreRam,
            .video_frame_rgb = c.av_frame_alloc() orelse return error.BuyMoreRam,
            // TODO: Can we just use the same frame for audio and video?
            .audio_frame = c.av_frame_alloc() orelse return error.BuyMoreRam,
        };

        try self.openFile(path);
        try self.findStreams();
        try self.openCodecs();
        try self.setupConverter();

        return self;
    }

    pub fn deinit(self: *Self) void {
        c.avformat_close_input(@ptrCast(&self.format_context));
        c.avcodec_free_context(@ptrCast(&self.video_codec_context));
        c.av_frame_free(&self.video_frame);
        c.av_frame_free(&self.video_frame_rgb);
        c.av_packet_free(@ptrCast(&self.packet));
        c.sws_freeContext(self.sws_context);
        self.allocator.free(self.video_buffer);
    }

    pub fn decodeNextFrame(self: *Self) !?Frame {
        while (c.av_read_frame(self.format_context, self.packet) >= 0) {
            defer c.av_packet_unref(self.packet);

            if (self.packet.stream_index == self.video_stream_index) {
                if (try self.decodeVideoPacket()) |frame| {
                    return Frame{ .video = frame };
                }
            }

            if (self.packet.stream_index == self.audio_stream_index) {
                if (try self.decodeAudioPacket()) |frame| {
                    return Frame{ .audio = frame };
                }
            }
        }
        return null;
    }

    fn decodeVideoPacket(self: *Self) !?VideoFrame {
        var ret = c.avcodec_send_packet(self.video_codec_context, self.packet);
        if (ret < 0) {
            return error.VideoPacketDecodeFailed;
        }

        ret = c.avcodec_receive_frame(self.video_codec_context, self.video_frame);
        if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF) {
            return null;
        } else if (ret < 0) {
            return error.VideoPacketDecodeFailed;
        }

        _ = c.sws_scale(
            self.sws_context.?,
            &self.video_frame.?.data[0],
            &self.video_frame.?.linesize[0],
            0,
            self.video_codec_context.height,
            &self.video_frame_rgb.?.data[0],
            &self.video_frame_rgb.?.linesize[0],
        );

        return VideoFrame{
            .data = self.video_frame_rgb.?.data[0],
            .linesize = self.video_frame_rgb.?.linesize[0],
            .width = self.video_codec_context.width,
            .height = self.video_codec_context.height,
            .format = getPixelFormat(self.video_frame_rgb.?.format),
            .pts = self.video_frame_rgb.?.pts,
        };
    }

    fn decodeAudioPacket(self: *Self) !?AudioFrame {
        var ret = c.avcodec_send_packet(self.audio_codec_context, self.packet);
        if (ret < 0) {
            std.log.err("Error sending audio packet {}\n", .{ret});
            return error.AudioPacketDecodeFailed;
        }

        ret = c.avcodec_receive_frame(self.audio_codec_context, self.audio_frame);
        if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF) {
            return null;
        } else if (ret < 0) {
            return error.AudioPacketDecodeFailed;
        }

        return AudioFrame{};
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
        try self.openCodec(&self.video_codec_context, self.video_stream_index);
        try self.openCodec(&self.audio_codec_context, self.audio_stream_index);
    }

    fn openCodec(self: *Self, codec_context: **c.AVCodecContext, stream_index: c_int) !void {
        const stream_index_usize: usize = @intCast(stream_index);
        const codec = c.avcodec_find_decoder(self.format_context.?.streams[stream_index_usize].*.codecpar.*.codec_id);
        if (codec == null) {
            return error.OpenCodecError;
        }

        codec_context.* = c.avcodec_alloc_context3(codec) orelse return error.OpenCodecError;
        errdefer c.avcodec_free_context(@ptrCast(codec_context));

        if (c.avcodec_parameters_to_context(codec_context.*, self.format_context.?.streams[stream_index_usize].*.codecpar) < 0) {
            return error.OpenCodecError;
        }

        if (c.avcodec_open2(codec_context.*, codec, null) < 0) {
            return error.OpenCodecError;
        }
    }

    fn setupConverter(self: *Self) !void {
        const buf_size: usize = @intCast(self.video_codec_context.width * self.video_codec_context.height * 4);

        self.video_buffer = try self.allocator.alloc(u8, buf_size);
        errdefer self.allocator.free(self.video_buffer);

        _ = c.av_image_fill_arrays(
            &self.video_frame_rgb.?.data[0],
            &self.video_frame_rgb.?.linesize[0],
            self.video_buffer.ptr,
            c.AV_PIX_FMT_RGB0,
            self.video_codec_context.width,
            self.video_codec_context.height,
            1,
        );
        self.sws_context = c.sws_getContext(
            self.video_codec_context.width,
            self.video_codec_context.height,
            self.video_codec_context.pix_fmt,
            self.video_codec_context.width,
            self.video_codec_context.height,
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
