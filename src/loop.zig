const builtin = @import("builtin");
const std = @import("std");
const Kqueue = @import("backend.zig").Kqueue;
const Epoll = @import("backend.zig").Epoll;
const Channel = @import("channel.zig").Channel;
const Fiber = @import("fiber.zig").Fiber;

pub const Fd = std.posix.fd_t;
pub const ReadError = std.posix.ReadError;
pub const WriteError = std.posix.WriteError;

pub const Op = struct {
    next: ?*Op = null,
    data: union(enum) {
        read: struct { fd: Fd, buf: []u8, chan: *Channel(ReadError!?[]u8) },
        write: struct { fd: Fd, data: []const u8, chan: *Channel(WriteError!void) },
        fiber: *Fiber,

        pub fn fd(self: @This()) Fd {
            return switch (self) {
                .fiber => unreachable,
                inline else => |d| d.fd,
            };
        }

        pub fn rw(self: @This()) bool {
            // return switch (self) {
            //     .fiber => unreachable,
            //     .read => true,
            //     else => false,
            // };

            return @intFromEnum(self) % 2 == 0;
        }

        pub fn attempt(self: *@This()) bool {
            // std.debug.print("attempt: {s}\n", .{@tagName(self.*)});

            switch (self.*) {
                .fiber => |f| {
                    f.@"resume"();
                    return true; // Will be re-added when channel is readable again
                },
                .read => |*r| {
                    if (r.chan.isFull()) return false;

                    const n = std.posix.read(r.fd, r.buf) catch |e| {
                        if (e == error.WouldBlock) return false;
                        r.chan.push(e);
                        return true;
                    };

                    if (n == 0) {
                        r.chan.push(null);
                        return true;
                    } else {
                        r.chan.push(r.buf[0..n]);
                        return true;
                    }
                },
                .write => |*w| {
                    if (w.chan.isFull()) return false;

                    const n = std.posix.write(w.fd, w.data) catch |e| {
                        if (e == error.WouldBlock) return false;
                        w.chan.push(e);
                        return true;
                    };

                    if (n == w.data.len) {
                        w.chan.push({});
                        return true;
                    } else {
                        w.data = w.data[n..];
                        return false;
                    }
                },
            }
        }
    },

    pub fn take(q: *?*Op) ?*Op {
        const op = q.* orelse return null;
        q.* = op.next;
        return op;
    }

    pub fn prepend(q: *?*Op, op: *Op) void {
        op.next = q.*;
        q.* = op;
    }
};

pub const Loop = struct {
    ready: ?*Op = null,
    pending: ?*Op = null,
    // timers: ?*Op = null,
    waiting: usize = 0,

    pub fn add(self: *Loop, op: *Op) void {
        Op.prepend(if (op.data == .fiber) &self.ready else &self.pending, op);
    }

    pub fn run(self: *Loop) !void {
        const B = switch (builtin.os.tag) {
            .macos => Kqueue,
            .linux => Epoll,
            else => @compileError("TODO"),
        };

        var backend = try B.init();
        defer backend.deinit();

        try self.runWith(&backend);
    }

    pub fn runWith(self: *Loop, backend: anytype) !void {
        while (self.alive()) {
            while (Op.take(&self.ready)) |op| {
                if (!op.data.attempt()) {
                    self.add(op);
                }
            }

            try backend.tick(self);
        }
    }

    fn alive(self: *Loop) bool {
        return self.ready != null or
            self.pending != null or
            // self.timers != null or
            self.waiting > 0;
    }
};
