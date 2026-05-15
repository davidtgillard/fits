//! Example and test helpers for the FITS package layout (not used by the `fits` executable root).
//!
//! The CLI entrypoint is [`main`](../main.zig).

const std = @import("std");
const Io = std.Io;

/// Writes a short reminder message to the given writer (for samples and tests).
///
/// Parameters:
/// - `writer`: Destination writer for UTF-8 text.
///
/// Returns: nothing on success, or [`Io.Writer.Error`] if the write fails.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

/// Returns the sum of `a` and `b` (used by the included unit test).
///
/// Parameters:
/// - `a`: First summand.
/// - `b`: Second summand.
///
/// Returns: `a + b` as `i32` (overflow is undefined for extreme values as in normal Zig `+`).
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
