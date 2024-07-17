const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");

const pool = @import("pool.zig");
const PacketPool = pool.PacketPool;
const FramePool = pool.FramePool;
const Queue = @import("queue.zig").Queue;

const AudioQueue = Queue(AudioFrame);
const VideoQueue = Queue(VideoFrame);

pub const VideoFrame = struct {
    allocator: Allocator,
    width: c_int,
    height: c_int,
    data: []u8,
    linesize: c_int,
    pts: f64,

    pub fn deinit(self: *VideoFrame) void {
        self.allocator.free(self.data);
    }
};

pub const AudioFrame = struct {
    allocator: Allocator,
    num_channels: usize,
    sample_rate: usize,
    num_samples: usize,
    sample_size: usize,
    raw_data: []u8,
    pts: f64,

    pub fn deinit(self: *AudioFrame) void {
        self.allocator.free(self.raw_data);
    }

    pub fn getSamples(self: *AudioFrame, channel: usize) []u8 {
        return self.raw_data[channel * self.sample_size .. (channel + 1) * self.sample_size * self.num_samples];
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

    pub fn getPts(self: *Frame) f64 {
        switch (self.*) {
            .video => return self.video.pts,
            .audio => return self.audio.pts,
        }
    }
};

pub const Decoder = struct {
    allocator: Allocator,
    config: DecoderConfig,
    format_context: ?*c.AVFormatContext = null,
    codec_contexts: std.ArrayList(*c.AVCodecContext),
    sws_context: ?*c.SwsContext = null,
    swr_context: ?*c.SwrContext = null,
    video_stream_index: c_int,
    audio_stream_index: c_int,
    packet_pool: PacketPool,
    frame_pool: FramePool,
    audio_queue: *AudioQueue,
    video_queue: *VideoQueue,

    const Self = @This();

    pub const DecoderConfig = struct {
        file_path: []const u8,

        audio_sample_rate: u32 = 44100,
        audio_sample_fmt: c.AVSampleFormat = c.AV_SAMPLE_FMT_S16,
        audio_ch_layout_mask: u64 = c.AV_CH_LAYOUT_STEREO,

        pub fn getAudioChannelLayout(self: DecoderConfig) c.AVChannelLayout {
            var ch_layout: c.AVChannelLayout = undefined;
            _ = c.av_channel_layout_from_mask(&ch_layout, self.audio_ch_layout_mask);
            return ch_layout;
        }

        pub fn getSampleSize(self: DecoderConfig) u32 {
            return @intCast(c.av_get_bytes_per_sample(self.audio_sample_fmt));
        }
    };

    pub fn init(allocator: Allocator, config: DecoderConfig, audio_queue: *AudioQueue, video_queue: *VideoQueue) !Self {
        var self = Self{
            .allocator = allocator,
            .config = config,
            .codec_contexts = std.ArrayList(*c.AVCodecContext).init(allocator),
            .packet_pool = try PacketPool.init(allocator, 100),
            .frame_pool = try FramePool.init(allocator, 100),
            .video_stream_index = -1,
            .audio_stream_index = -1,
            .audio_queue = audio_queue,
            .video_queue = video_queue,
        };

        try self.openFile(config.file_path);
        try self.findStreams();
        try self.openCodecs();
        try self.setupConverter(config);

        return self;
    }

    pub fn deinit(self: *Self) void {
        c.avformat_close_input(@ptrCast(&self.format_context));
        for (self.codec_contexts.items) |*codec_context| {
            c.avcodec_free_context(@ptrCast(codec_context));
        }
        self.codec_contexts.deinit();
        c.sws_freeContext(self.sws_context);
        c.swr_free(&self.swr_context);
        self.packet_pool.deinit();
        self.frame_pool.deinit();
    }

    pub fn getAudioCodecContext(self: *Self) !*c.AVCodecContext {
        return try self.getCodecContext(self.audio_stream_index);
    }

    pub fn getVideoCodecContext(self: *Self) !*c.AVCodecContext {
        return try self.getCodecContext(self.video_stream_index);
    }

    pub fn getAudioStream(self: *Self) *c.AVStream {
        return self.format_context.?.streams[@intCast(self.audio_stream_index)];
    }

    pub fn getVideoStream(self: *Self) *c.AVStream {
        return self.format_context.?.streams[@intCast(self.video_stream_index)];
    }

    pub fn decodeLoop(self: *Self) !void {
        var frame = try self.decodeNextFrame() orelse {
            return error.EndOfFile;
        };
        errdefer frame.deinit();

        switch (frame) {
            .video => |video| {
                self.video_queue.push(video) catch |err| {
                    std.debug.print("Failed to push video frame to queue: {}\n", .{err});
                };
            },
            .audio => |audio| {
                self.audio_queue.push(audio) catch |err| {
                    std.debug.print("Failed to push audio frame to queue: {}\n", .{err});
                };
            },
        }
    }

    pub fn readPacket(self: *Self) !?*c.AVPacket {
        const packet = self.packet_pool.acquire() orelse return error.PacketPoolExhausted;
        errdefer self.packet_pool.release(packet) catch {
            std.debug.print("Failed to release packet\n", .{});
        };

        const ret = c.av_read_frame(self.format_context, packet);

        if (ret == c.AVERROR_EOF) {
            try self.packet_pool.release(packet);
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
            try self.frame_pool.release(frame);
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
                std.debug.print("No more packets \n", .{});
                return null;
            };
            defer self.packet_pool.release(packet) catch {
                std.debug.print("Failed to release packet\n", .{});
            };

            const frame = try self.decodePacket(packet) orelse continue;
            defer self.frame_pool.release(frame) catch {
                std.debug.print("Failed to release frame\n", .{});
            };

            if (packet.stream_index == self.video_stream_index) {
                if (try self.processVideoFrame(frame)) |video_frame| {
                    return .{ .video = video_frame };
                }
            } else if (packet.stream_index == self.audio_stream_index) {
                if (try self.processAudioFrame(frame)) |audio_frame| {
                    return .{ .audio = audio_frame };
                }
            }
        }
        return null;
    }

    fn processAudioFrame(self: *Self, frame: *c.AVFrame) !?AudioFrame {
        const codec_context = try self.getCodecContext(self.audio_stream_index);
        const stream = self.getAudioStream();

        const src_sample_rate = codec_context.sample_rate;
        const src_nb_samples = frame.nb_samples;

        const dst_sample_fmt = self.config.audio_sample_fmt;
        const dst_ch_layout = self.config.getAudioChannelLayout();
        const dst_sample_rate = self.config.audio_sample_rate;

        const delay = c.swr_get_delay(self.swr_context, src_sample_rate);

        var dst_nb_samples = c.av_rescale_rnd(
            delay + src_nb_samples,
            dst_sample_rate,
            src_sample_rate,
            c.AV_ROUND_UP,
        );

        const dst_nb_channels = dst_ch_layout.nb_channels;
        const dst_sample_size = self.config.getSampleSize();

        var resampled_data: [*][*]u8 = undefined;
        var dst_linesize: c_int = undefined;

        var ret = c.av_samples_alloc_array_and_samples(
            @ptrCast(&resampled_data),
            &dst_linesize,
            dst_nb_channels,
            @intCast(dst_nb_samples),
            dst_sample_fmt,
            1,
        );
        defer c.av_freep(@ptrCast(&resampled_data[0]));
        // defer c.av_freep(@ptrCast(&resampled_data));

        if (ret < 0) {
            return error.SampleAllocFailed;
        }

        dst_nb_samples = c.av_rescale_rnd(
            c.swr_get_delay(self.swr_context, src_sample_rate) + src_nb_samples,
            dst_sample_rate,
            src_sample_rate,
            c.AV_ROUND_UP,
        );

        ret = c.swr_convert(
            self.swr_context,
            resampled_data,
            @intCast(dst_nb_samples),
            @ptrCast(frame.extended_data),
            @intCast(src_nb_samples),
        );
        if (ret < 0) {
            return error.SampleConversionFailed;
        }

        const resampled_data_size: usize = @intCast(c.av_samples_get_buffer_size(
            &dst_linesize,
            dst_nb_channels,
            ret,
            dst_sample_fmt,
            1,
        ));

        const raw_data = try self.allocator.alloc(u8, resampled_data_size);
        @memcpy(raw_data, resampled_data[0][0..resampled_data_size]);

        const num_samples: usize = @intCast(ret);
        const num_channels: usize = @intCast(dst_nb_channels);

        // Flush
        ret = c.swr_convert(
            self.swr_context,
            resampled_data,
            @intCast(dst_nb_samples),
            null,
            0,
        );
        std.debug.print("flushed samples: {}\n", .{ret});
        const time_base = stream.*.time_base;

        var pts_f: f64 = @floatFromInt(frame.pts);
        pts_f *= c.av_q2d(time_base);

        return AudioFrame{
            .allocator = self.allocator,
            .num_channels = num_channels,
            .sample_rate = @intCast(dst_sample_rate),
            .num_samples = num_samples,
            .raw_data = raw_data,
            .sample_size = dst_sample_size,
            .pts = pts_f,
        };
    }

    fn processVideoFrame(self: *Self, frame: *c.AVFrame) !?VideoFrame {
        const codec_context = try self.getCodecContext(self.video_stream_index);
        const stream = self.getVideoStream();

        var rgb_frame = self.frame_pool.acquire() orelse return error.FramePoolExhausted;
        defer self.frame_pool.release(rgb_frame) catch {
            std.debug.print("Failed to release frame\n", .{});
        };
        const buf_size: usize = @intCast(codec_context.width * codec_context.height * 4);

        const rgb_buffer = try self.allocator.alloc(u8, buf_size);
        const dst_format = c.AV_PIX_FMT_RGB0;
        const dst_height = codec_context.height;
        const dst_width = codec_context.width;

        _ = c.av_image_fill_arrays(
            &rgb_frame.data[0],
            &rgb_frame.linesize[0],
            rgb_buffer.ptr,
            dst_format,
            dst_width,
            dst_height,
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

        const time_base = stream.*.time_base;

        var pts_f: f64 = @floatFromInt(frame.pts);
        pts_f *= c.av_q2d(time_base);

        return VideoFrame{
            .allocator = self.allocator,
            .data = rgb_buffer,
            .linesize = rgb_frame.linesize[0],
            .width = codec_context.width,
            .height = codec_context.height,
            .pts = pts_f,
        };
    }

    fn getCodecContext(self: *Self, stream_index: c_int) !*c.AVCodecContext {
        if (stream_index < 0 or stream_index >= self.codec_contexts.items.len) {
            return error.InvalidStreamIndex;
        }

        return self.codec_contexts.items[@intCast(stream_index)];
    }

    fn openFile(self: *Self, path: []const u8) !void {
        if (c.avformat_open_input(&self.format_context, path.ptr, null, null) < 0) {
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

    fn setupConverter(self: *Self, config: DecoderConfig) !void {
        const video_ctx = try self.getVideoCodecContext();
        const audio_ctx = try self.getAudioCodecContext();

        self.sws_context = c.sws_getContext(
            video_ctx.width,
            video_ctx.height,
            video_ctx.pix_fmt,
            video_ctx.width,
            video_ctx.height,
            c.AV_PIX_FMT_RGB0,
            c.SWS_BILINEAR,
            null,
            null,
            null,
        ) orelse return error.SwsContextCreationFailed;
        errdefer c.sws_freeContext(self.sws_context);

        self.swr_context = c.swr_alloc() orelse return error.SwrContextCreationFailed;
        errdefer c.swr_free(&self.swr_context);

        var ch_layout = config.getAudioChannelLayout();
        var ret = c.swr_alloc_set_opts2(
            &self.swr_context,
            &ch_layout,
            config.audio_sample_fmt,
            @intCast(config.audio_sample_rate),
            &audio_ctx.ch_layout,
            audio_ctx.sample_fmt,
            audio_ctx.sample_rate,
            0,
            null,
        );

        if (ret < 0) {
            return error.SwrContextInitFailed;
        }

        ret = c.swr_init(self.swr_context);
        if (ret < 0) {
            return error.SwrContextInitFailed;
        }
    }
};
