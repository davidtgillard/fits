//! C-heap string helpers (`malloc` allocator).

const std = @import("std");
const c_errors = @import("c_errors.zig");

const c_allocator = c_errors.c_allocator;

/// Copies `s` to a null-terminated buffer on the C heap.
pub fn allocCString(s: []const u8) ![*:0]u8 {
    const copy = try c_allocator.alloc(u8, s.len + 1);
    @memcpy(copy[0..s.len], s);
    copy[s.len] = 0;
    return @as([*:0]u8, @ptrCast(copy.ptr));
}

/// Frees a string returned from [`allocCString`].
pub fn freeCString(ptr: ?[*:0]const u8) void {
    if (ptr) |p| {
        const len = std.mem.len(p);
        const buf: [*]u8 = @ptrCast(@constCast(p));
        c_allocator.free(buf[0 .. len + 1]);
    }
}
