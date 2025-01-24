const std = @import("std");
const nio = @import("nio.zig");
const Op = @import("loop.zig").Op;
const Fiber = @import("fiber.zig").Fiber;

pub fn Channel(comptime T: type) type {
    return struct {
        buf: []T,
        r: usize = 0, // TODO: smaller
        w: usize = 0,
        q: ?*Op = null,

        const CH = @This();

        pub const frozen: CH = .init(&.{});

        pub fn init(buf: []T) CH {
            return .{ .buf = buf };
        }

        pub fn isEmpty(self: CH) bool {
            return self.r == self.w;
        }

        pub fn isFull(self: CH) bool {
            return self.r == (self.w + self.buf.len) % (2 * self.buf.len);
        }

        pub fn next(self: *CH) T {
            while (self.isEmpty()) Fiber.yield(&self.q);
            const v = self.buf[self.r];
            self.r = (self.r + 1) % self.buf.len;
            self.maybeResume();
            return v;
        }

        pub fn push(self: *CH, v: T) void {
            while (self.isFull()) Fiber.yield(&self.q);
            self.buf[(self.w + 1) % self.buf.len] = v;
            self.w = (self.w + 1) % (2 * self.buf.len);
            return self.maybeResume();
        }

        pub fn once(self: *CH) T {
            std.debug.assert(self.buf.len == 0);

            var buf: [1]T = undefined;
            self.* = .init(&buf);
            defer self.* = .frozen;

            return self.next();
        }

        fn maybeResume(self: *CH) void {
            const op = self.q orelse return;
            self.q = op.next;
            nio.loop.add(op);
        }
    };
}
