//! Interactive yes/no prompts for CLI commands.

const std = @import("std");

const Io = std.Io;

/// Returns whether interactive prompts may be shown.
///
/// Parameters:
/// - `io`: Process I/O for TTY detection on stdin.
/// - `no_interactive`: When true, prompts are disabled.
///
/// Returns: `true` when stdin is a TTY and `no_interactive` is false.
pub fn canPrompt(io: Io, no_interactive: bool) bool {
    if (no_interactive) return false;
    return Io.File.stdin().isTty(io) catch false;
}

/// Asks a yes/no question on stderr; empty input or anything other than y/yes means no.
///
/// Parameters:
/// - `io`: Process I/O for stdin read.
/// - `allocator`: Unused today; reserved for future line buffering growth.
/// - `question`: Prompt text without trailing `[y/N]`.
///
/// Returns: `true` when the user answers y/yes (case-insensitive).
pub fn askYesNo(io: Io, allocator: std.mem.Allocator, question: []const u8) !bool {
    _ = allocator;
    std.debug.print("{s} [y/N]: ", .{question});

    var buf: [512]u8 = undefined;
    var file_reader = Io.File.stdin().reader(io, &buf);
    const line = file_reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.StreamTooLong => return false,
        error.EndOfStream => "",
        else => return err,
    };
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}
