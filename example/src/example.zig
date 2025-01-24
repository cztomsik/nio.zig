const std = @import("std");
const nio = @import("nio");

var x: [100 * 1024]u8 = undefined; // TODO: looks like we need a lot (otherwise panic/printing/everything fails randomly)

pub const Panic = std.debug.SimplePanic;

pub fn main() !void {
    const fib = nio.Fiber.init(&x, example);
    nio.loop.add(&fib.op);

    try nio.loop.run();
}

fn example() !void {
    std.debug.print("connect\n", .{});
    const conn = try nio.connect("www.google.com", 80);
    defer nio.close(conn);

    std.debug.print("write\n", .{});
    try nio.write(conn, "GET / HTTP/1.1\r\nHost: www.google.com\r\nUser-Agent: nio.zig\r\nConnection: close\r\n\r\n");

    var res = std.ArrayList(u8).init(std.heap.page_allocator);
    defer res.deinit();

    var buf: [1024]u8 = undefined;
    std.debug.print("read\n", .{});
    while (try nio.read(conn, &buf)) |data| {
        std.debug.print("got {}\n", .{data.len});
        try res.appendSlice(data);
    }

    std.debug.print("Response:\n{s}\n", .{res.items});
}
