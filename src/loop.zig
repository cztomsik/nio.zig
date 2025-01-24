const std = @import("std");

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

        fn fd(self: @This()) Fd {
            return switch (self) {
                .fiber => unreachable,
                inline else => |d| d.fd,
            };
        }

        fn rw(self: @This()) bool {
            return switch (self) {
                .fiber => unreachable,
                .read => true,
                else => false,
            };
        }

        fn attempt(self: *@This()) bool {
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
};

pub const Loop = struct {
    kq: i32,
    ready: ?*Op = null,
    pending: ?*Op = null,

    pub threadlocal var current: ?*Loop = null;

    pub fn init() !Loop {
        return .{
            .kq = try std.posix.kqueue(),
        };
    }

    pub fn deinit(self: *Loop) void {
        std.posix.close(self.kq);
    }

    pub fn add(self: *Loop, op: *Op) void {
        prepend(if (op.data == .fiber) &self.ready else &self.pending, op);
    }

    pub fn run(self: *Loop) !void {
        var buf: [16]std.posix.Kevent = undefined;

        current = self;
        defer current = null;

        for (0..11) |_| { // do just a few ticks for the sake of PoC
            // std.debug.print("tick {}\n", .{i});

            while (take(&self.ready)) |op| {
                if (!op.data.attempt()) {
                    self.add(op);
                }
            }

            const chs = self.prepareChanges(&buf);
            var t: std.posix.timespec = .{ .nsec = 500_000_000, .sec = 0 }; // TODO: (nextTimer or -1) if we didn't register anything

            const n = try std.posix.kevent(self.kq, chs, &buf, &t);

            for (buf[0..n]) |ev| {
                const op: *Op = @ptrFromInt(ev.udata);
                prepend(&self.ready, op);
            }
        }
    }

    fn prepareChanges(self: *Loop, buf: []std.posix.Kevent) []const std.posix.Kevent {
        for (buf, 0..) |*e, i| {
            const op = take(&self.pending) orelse return buf[0..i];

            e.* = .{
                .ident = @intCast(op.data.fd()),
                .filter = if (op.data.rw()) std.c.EVFILT.READ else std.c.EVFILT.WRITE,
                .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(op),
            };
        } else return buf;
    }
};

fn take(q: *?*Op) ?*Op {
    const op = q.* orelse return null;
    q.* = op.next;
    return op;
}

fn prepend(q: *?*Op, op: *Op) void {
    op.next = q.*;
    q.* = op;
}
