const std = @import("std");

pub const Fd = std.posix.fd_t;
pub const ReadError = std.posix.ReadError;
pub const WriteError = std.posix.WriteError;
pub const ConnectError = std.posix.ConnectError;

pub const Loop = @import("loop.zig").Loop;
pub const Op = @import("loop.zig").Op;
pub const Channel = @import("channel.zig").Channel;
pub const Fiber = @import("fiber.zig").Fiber;

pub fn connect(host: []const u8, port: u16) !Fd {
    // TODO: connect() should be non-blocking too
    const conn = try std.net.tcpConnectToHost(std.heap.page_allocator, host, port);
    _ = try std.posix.fcntl(conn.handle, std.posix.F.SETFL, std.posix.SOCK.NONBLOCK);
    return conn.handle;
}

pub fn close(x: anytype) void {
    // TODO
    _ = std.posix.close(x);
}

pub fn read(x: anytype, buf: []u8) ReadError!?[]u8 {
    var chan: Channel(ReadError!?[]u8) = .frozen;
    var op: Op = .{ .data = .{ .read = .{ .fd = x, .buf = buf, .chan = &chan } } };
    Loop.current.?.add(&op);
    return chan.once();
}

pub fn write(x: anytype, data: []const u8) WriteError!void {
    var chan: Channel(WriteError!void) = .frozen;
    var op: Op = .{ .data = .{ .write = .{ .fd = x, .data = data, .chan = &chan } } };
    Loop.current.?.add(&op);
    return chan.once();
}
