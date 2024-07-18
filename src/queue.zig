const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayList(T),
        capacity: usize,
        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        not_full: std.Thread.Condition,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return Self{
                .items = try std.ArrayList(T).initCapacity(allocator, capacity),
                .mutex = .{},
                .not_empty = .{},
                .not_full = .{},
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        pub fn push(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.items.items.len >= self.capacity) {
                self.not_full.wait(&self.mutex);
            }

            try self.items.append(item);
            self.not_empty.signal();
        }

        pub fn pop(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.items.items.len == 0) {
                self.not_empty.wait(&self.mutex);
            }

            self.not_full.signal();
            return self.items.orderedRemove(0);
        }

        pub fn peek(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.items.items.len == 0) {
                return null;
            }

            return self.items.items[0];
        }
    };
}
