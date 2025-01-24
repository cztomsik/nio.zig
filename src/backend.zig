const std = @import("std");
const Loop = @import("loop.zig").Loop;
const Op = @import("loop.zig").Op;

pub const Kqueue = struct {
    kq: i32,

    pub fn init() !Kqueue {
        return .{
            .kq = try std.posix.kqueue(),
        };
    }

    pub fn deinit(self: *Kqueue) void {
        std.posix.close(self.kq);
    }

    pub fn tick(self: *Kqueue, loop: *Loop) !void {
        var buf: [16]std.posix.Kevent = undefined;

        const chs = prepareChanges(loop, &buf);
        var t: std.posix.timespec = .{ .nsec = 500_000_000, .sec = 0 }; // TODO: (nextTimer or -1) if we didn't register anything

        const n = try std.posix.kevent(self.kq, chs, &buf, &t);

        for (buf[0..n]) |ev| {
            const op: *Op = @ptrFromInt(ev.udata);
            Op.prepend(&loop.ready, op);
        }
    }

    fn prepareChanges(loop: *Loop, buf: []std.posix.Kevent) []const std.posix.Kevent {
        for (buf, 0..) |*e, i| {
            const op = Op.take(&loop.pending) orelse return buf[0..i];

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

pub const Epoll = struct {};
