const std = @import("std");
const Op = @import("loop.zig").Op;
const jmp_buf = [32]c_long; // https://git.musl-libc.org/cgit/musl/tree/arch/arm/bits/setjmp.h?id=d6c0efe106b1016108207fb6872820c06dcef4f8

threadlocal var curr: ?*Fiber = null;

pub const Fiber = struct {
    op: Op,
    env: jmp_buf,
    prev: jmp_buf,

    // TODO: args, err handling, ...
    pub fn init(stack: []u8, fun: anytype) *Fiber {
        @memset(stack, 0);

        const self: *Fiber = @ptrCast(@alignCast(stack.ptr));

        self.op = .{ .data = .{ .fiber = self } };

        const H = struct {
            fn entry() callconv(.C) noreturn {
                // std.debug.print("entry\n", .{});
                fun() catch |e| {
                    std.debug.print("err: {s}\n", .{@errorName(e)});
                    @panic("err");
                };

                var x: ?*Op = null;
                Fiber.yield(&x);
                unreachable;
            }
        };

        const sp: **usize = @ptrCast(@alignCast(&self.env[104 / 8]));
        sp.* = @ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len, 2 * @sizeOf(usize))); // Growing DOWN, dword-aligned, at least for macos

        const entry: **const @TypeOf(H.entry) = @ptrCast(@alignCast(&self.env[88 / 8]));
        entry.* = &H.entry;

        return self;
    }

    pub noinline fn @"resume"(self: *Fiber) callconv(.C) void {
        // std.debug.print("resume\n", .{});
        curr = self;
        if (setjmp(&self.prev) != 0) return;
        longjmp(&self.env, 1);
    }

    pub noinline fn yield(q: *?*Op) callconv(.C) void {
        // std.debug.print("yield\n", .{});
        const fib = curr orelse unreachable;

        fib.op.next = q.*;
        q.* = &fib.op;

        if (setjmp(&fib.env) != 0) return;
        longjmp(&fib.prev, 1);
    }
};

extern fn setjmp(*anyopaque) c_int;
extern fn longjmp(*anyopaque, c_int) noreturn;

// (MIT) https://git.musl-libc.org/cgit/musl/tree/src/setjmp/aarch64
comptime {
    asm (
        \\.global _setjmp
        \\_setjmp:
        \\  stp x19, x20, [x0,#0]
        \\  stp x21, x22, [x0,#16]
        \\  stp x23, x24, [x0,#32]
        \\  stp x25, x26, [x0,#48]
        \\  stp x27, x28, [x0,#64]
        \\  stp x29, x30, [x0,#80]
        \\  mov x2, sp
        \\  str x2, [x0,#104]
        \\  stp  d8,  d9, [x0,#112]
        \\  stp d10, d11, [x0,#128]
        \\  stp d12, d13, [x0,#144]
        \\  stp d14, d15, [x0,#160]
        \\  mov x0, #0
        \\  ret
        \\
        \\.global _longjmp
        \\_longjmp:
        \\  ldp x19, x20, [x0,#0]
        \\  ldp x21, x22, [x0,#16]
        \\  ldp x23, x24, [x0,#32]
        \\  ldp x25, x26, [x0,#48]
        \\  ldp x27, x28, [x0,#64]
        \\  ldp x29, x30, [x0,#80]
        \\  ldr x2, [x0,#104]
        \\  mov sp, x2
        \\  ldp d8 , d9, [x0,#112]
        \\  ldp d10, d11, [x0,#128]
        \\  ldp d12, d13, [x0,#144]
        \\  ldp d14, d15, [x0,#160]
        \\  cmp w1, 0
        \\  csinc w0, w1, wzr, ne
        \\  br x30
    );
}
