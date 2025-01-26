// NOTE: We only support one read and one write operation per file descriptor.
// This should be fine, because concurrent reading from the same byte stream
// is likely a (serious) mistake. So the problem is not that we don't support
// something which nobody wants to do. The problem is rather how to detect this
// and tell the user. This is currently a TODO. When we add timeouts (TODO),
// such cases should pop-out eventually, and maybe that's enough.
//
// BTW: if you ever hit this, just create a channel and share it across all your
//      readers/writers and that's it.

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
        loop.waiting += chs.len;

        const n = try std.posix.kevent(self.kq, chs, &buf, &t);

        for (buf[0..n]) |ev| {
            const op: *Op = @ptrFromInt(ev.udata);
            Op.prepend(&loop.ready, op);
            loop.waiting -= 1;
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

// NOTE: it's probably not worth spending more time here
//       https://idea.popcount.org/2017-02-20-epoll-is-fundamentally-broken-12/
pub const Epoll = struct {
    epfds: [3]std.posix.fd_t, // IN, OUT + one "parent"

    pub fn init() !Epoll {
        var epfds: [3]std.posix.fd_t = undefined;

        inline for (0..epfds.len) |i| {
            epfds[i] = try std.posix.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
            errdefer std.posix.close(epfds[i]);
        }

        for (0..2) |i| {
            var ev: std.os.linux.epoll_event = .{
                .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.OUT,
                .data = .{ .fd = epfds[i] },
            };
            try std.posix.epoll_ctl(epfds[2], std.os.linux.EPOLL.CTL_ADD, epfds[i], &ev);
        }

        return .{
            .epfds = epfds,
        };
    }

    pub fn deinit(self: *Epoll) void {
        for (self.epfds) |fd| {
            std.posix.close(fd);
        }
    }

    pub fn tick(self: *Epoll, loop: *Loop) !void {
        var buf: [16]std.os.linux.epoll_event = undefined;

        while (Op.take(&loop.pending)) |op| {
            var ev: std.os.linux.epoll_event = .{
                .events = std.os.linux.EPOLL.ONESHOT | @as(u32, if (op.data.rw()) std.os.linux.EPOLL.IN else std.os.linux.EPOLL.OUT),
                .data = .{ .ptr = @intFromPtr(op) },
            };

            try std.posix.epoll_ctl(self.epfds[@intFromBool(op.data.rw())], std.os.linux.EPOLL.CTL_ADD, op.data.fd(), &ev);
            loop.waiting += 1;
        }

        const n1 = std.posix.epoll_wait(self.epfds[2], &buf, 500); // TODO: real timeout/timers

        for (buf[0..n1]) |ev1| {
            const n2 = std.posix.epoll_wait(ev1.data.fd, &buf, 0);

            for (buf[0..n2]) |ev2| {
                const op: *Op = @ptrFromInt(ev2.data.ptr);
                var ev: std.os.linux.epoll_event = undefined;
                try std.posix.epoll_ctl(ev1.data.fd, std.os.linux.EPOLL.CTL_DEL, op.data.fd(), &ev);

                Op.prepend(&loop.ready, op);
                loop.waiting -= 1;
            }
        }
    }
};
