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
    data: [4][*]u8, // Up to 4 planes for different pixel formats
    linesize: [4]c_int, // Stride for each plane
    pts: i64, // Presentation timestamp
};

pub const Frame = union(enum) {
    video: VideoFrame,
};

pub const Decoder = struct {
    allocator: Allocator,
    format_context: ?*c.AVFormatContext,
    video_codec_context: ?*c.AVCodecContext,
    video_stream_index: c_int,
    video_stream: ?*c.AVStream,
    video_frame: ?*c.AVFrame,
    video_frame_rgb: ?*c.AVFrame,
    packet: c.AVPacket,
    video_buffer: [*c]u8,

    const Self = @This();

    pub fn init(allocator: Allocator, path: [:0]const u8) !Self {
        var self = Self{
            .allocator = allocator,
            .format_context = null,
            .video_codec_context = null,
            .video_stream_index = -1,
            .video_stream = null,
            .video_frame = null,
            .video_frame_rgb = null,
            .packet = undefined,
            .video_buffer = undefined,
        };

        // First we need to
        try self.openFile(path);
        try self.findStreams();
        try self.openCodec();

        return self;
    }

    pub fn deinit(self: *Self) void {
        c.avformat_close_input(@ptrCast(&self.format_context));
        c.avcodec_free_context(@ptrCast(&self.video_codec_context));
        c.av_frame_free(&self.video_frame);
        c.av_frame_free(&self.video_frame_rgb);
    }

    pub fn decodeNextFrame(self: *Self) !?Frame {
        while (c.av_read_frame(self.format_context, &self.packet) >= 0) {
            defer c.av_packet_unref(&self.packet);

            if (self.packet.stream_index == self.video_stream_index) {
                if (try self.decodeVideoPacket()) |frame| {
                    return Frame{ .video = frame };
                }
            }
        }
        return null;
    }

    fn decodeVideoPacket(self: *Self) !?VideoFrame {
        var ret = c.avcodec_send_packet(self.video_codec_context, &self.packet);
        if (ret < 0) {
            return error.VideoPacketDecodeFailed;
        }

        ret = c.avcodec_receive_frame(self.video_codec_context, self.video_frame);
        if (ret == c.AVERROR(c.EAGAIN) or ret == c.AVERROR_EOF) {
            return null;
        } else if (ret < 0) {
            return error.VideoPacketDecodeFailed;
        }

        const format = switch (self.video_codec_context.?.pix_fmt) {
            c.AV_PIX_FMT_YUV420P => PixelFormat.YUV420P,
            c.AV_PIX_FMT_RGB24 => PixelFormat.RGB24,
            c.AV_PIX_FMT_YUVJ420P => PixelFormat.YUVJ420P,
            else => {
                std.debug.print("Unsupported pixel format: {s}\n", .{c.av_pix_fmt_desc_get(self.video_codec_context.?.pix_fmt).*.name});
                return error.UnsupportedPixelFormat;
            },
        };

        var frame = VideoFrame{
            .width = self.video_codec_context.?.width,
            .height = self.video_codec_context.?.height,
            .pts = self.video_frame.?.pts,
            .format = format,
            .data = undefined,
            .linesize = undefined,
        };

        var i: usize = 0;
        while (i < 4 and self.video_frame.?.data[i] != null) : (i += 1) {
            frame.data[i] = self.video_frame.?.data[i];
            frame.linesize[i] = self.video_frame.?.linesize[i];
        }
        return frame;
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
        var index: c_uint = 0;
        while (index < self.format_context.?.nb_streams) : (index += 1) {
            if (self.format_context.?.streams[index].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
                self.video_stream_index = @intCast(index);
                break;
            }
        }

        if (self.video_stream_index == -1) {
            return error.NoVideoStreamFound;
        }
    }

    fn openCodec(self: *Self) !void {
        const video_idx: usize = @intCast(self.video_stream_index);
        const video_codec = c.avcodec_find_decoder(self.format_context.?.streams[video_idx].*.codecpar.*.codec_id);
        if (video_codec == null) {
            return error.OpenCodecError;
        }

        self.video_codec_context = c.avcodec_alloc_context3(video_codec) orelse return error.OpenCodecError;
        errdefer c.avcodec_free_context(@ptrCast(&self.video_codec_context));

        if (c.avcodec_parameters_to_context(self.video_codec_context, self.format_context.?.streams[video_idx].*.codecpar) < 0) {
            return error.OpenCodecError;
        }

        if (c.avcodec_open2(self.video_codec_context, video_codec, null) < 0) {
            return error.OpenCodecError;
        }

        self.video_frame = c.av_frame_alloc() orelse return error.BuyMoreRam;
        self.video_frame_rgb = c.av_frame_alloc() orelse return error.BuyMoreRam;
    }
};
