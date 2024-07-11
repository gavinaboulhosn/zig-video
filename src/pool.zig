const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");

pub const PacketPool = struct {
    mutex: std.Thread.Mutex,
    packets: std.ArrayList(*c.AVPacket),

    pub fn init(allocator: Allocator, capacity: usize) !PacketPool {
        var self = PacketPool{
            .packets = try std.ArrayList(*c.AVPacket).initCapacity(allocator, capacity),
            .mutex = .{},
        };

        var i: usize = 0;
        while (i < capacity) : (i += 1) {
            const packet = c.av_packet_alloc() orelse return error.BuyMoreRam;
            try self.packets.append(packet);
        }

        return self;
    }

    pub fn deinit(self: *PacketPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.packets.items) |*packet| {
            c.av_packet_free(@ptrCast(packet));
        }

        self.packets.deinit();
    }

    pub fn acquire(self: *PacketPool) ?*c.AVPacket {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.packets.popOrNull();
    }

    pub fn release(self: *PacketPool, packet: *c.AVPacket) !void {
        c.av_packet_unref(packet);
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.packets.append(packet);
    }
};

pub const FramePool = struct {
    mutex: std.Thread.Mutex,
    frames: std.ArrayList(*c.AVFrame),

    pub fn init(allocator: Allocator, capacity: usize) !FramePool {
        var self = FramePool{
            .frames = try std.ArrayList(*c.AVFrame).initCapacity(allocator, capacity),
            .mutex = .{},
        };

        var i: usize = 0;
        while (i < capacity) : (i += 1) {
            const frame = c.av_frame_alloc() orelse return error.BuyMoreRam;
            try self.frames.append(frame);
        }

        return self;
    }

    pub fn deinit(self: *FramePool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.frames.items) |*frame| {
            c.av_frame_free(@ptrCast(frame));
        }

        self.frames.deinit();
    }

    pub fn acquire(self: *FramePool) ?*c.AVFrame {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.frames.popOrNull();
    }

    pub fn release(self: *FramePool, frame: *c.AVFrame) !void {
        c.av_frame_unref(frame);
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.frames.append(frame);
    }
};
