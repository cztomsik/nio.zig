const std = @import("std");

pub fn build(b: *std.Build) !void {
    _ = b.addModule("nio", .{
        .root_source_file = b.path("src/nio.zig"),
    });
}
