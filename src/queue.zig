//an atomic queue

const std = @import("std");
const warn = std.debug.warn;

const ArrayList = std.ArrayList;

pub fn AtomicQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        front: usize,
        back: usize,
        mutex: std.Mutex,
        buffer: ArrayList(T),

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .buffer = ArrayList(T).init(allocator),
                .front = 0,
                .back = 0,
                .mutex = std.Mutex{},
            };
        }

        fn deinit(self: *Self) void {
            std.debug.warn("atomic queue deinit\n", .{});
            self.buffer.deinit();
        }

        pub fn push(self: *Self, value: T) !void {
            const held = self.mutex.acquire();
            defer held.release();

            try self.insertCheck();
            try self.buffer.append(value);
            self.back += 1;
        }

        pub fn pop(self: *Self) ?T {
            const held = self.mutex.acquire();
            defer held.release();

            if (self._empty()) return null;

            const value = self.buffer.items[self.front];
            self.front += 1;

            return value;
        }

        pub fn empty(self: *Self) bool {
            const held = self.mutex.acquire();
            defer held.release();

            return self._empty();
        }

        pub fn size(self: *Self) usize {
            const held = self.mutex.acquire();
            defer held.release();

            return self._size();
        }

        fn _empty(self: *Self) bool {
            return self.front == self.back;
        }

        fn _size(self: *Self) usize {
            return self.back - self.front;
        }

        //make sure we can insert an item. Move of allocate memory if needed.
        fn insertCheck(self: *Self) !void {
            const desired_capacity = (self._size() + 1) * 2; // double capacity is desired to prevent too many mem copies
            if (desired_capacity < self.buffer.capacity)
                try self.buffer.ensureCapacity(desired_capacity);
            if (self.buffer.capacity < self.back + 1) {
                if (self.front > 0) { //we can make space by moving
                    const N = self.back - self.front;
                    std.mem.copy(T, self.buffer.items[0..], self.buffer.items[self.front..]);
                    try self.buffer.resize(N);
                    self.front = 0;
                    self.back = N;
                } else { //there is no space, double capacity
                    if (self.buffer.capacity == 0) {
                        try self.buffer.ensureCapacity(1);
                    } else {
                        try self.buffer.ensureCapacity(self.buffer.capacity * 2);
                    }
                }
            }
        }
    };
}
