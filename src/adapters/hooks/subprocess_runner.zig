//! Spawn hook subprocess: write JSON to stdin, read stdout/stderr with byte limits.
//! Host-only; hooks themselves perform no process management.

const std = @import("std");
const Io = std.Io;

/// Result of [`runHook`]. Caller frees `stdout` and `stderr` with `allocator`.
pub const RunHookResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

pub const RunHookError = error{
    StreamTooLong,
    InvalidArgv,
    InvalidStdinPipe,
} || std.mem.Allocator.Error || std.process.SpawnError || std.process.Child.WaitError || Io.File.WritePositionalError || Io.File.MultiReader.FillError || Io.File.MultiReader.UnendingError;

/// Runs `argv[0]` with `argv`, sending `stdin_bytes` to stdin and collecting stdout/stderr until the child exits.
///
/// Parameters:
/// - `allocator`: Owns returned `stdout` and `stderr`.
/// - `io`: Process I/O (blocking).
/// - `argv`: Executable path at `[0]` and arguments; must be non-empty.
/// - `stdin_bytes`: Full request body written before the child's stdin is closed.
/// - `max_stdout_bytes` / `max_stderr_bytes`: hard caps per stream ([`Io.Limit`]).
/// - `timeout`: [`Io.Timeout`] for reading pipes (e.g. `.none` or `.duration`).
///
/// Returns: collected streams and exit status. Nonzero exit does not fail here; caller decides.
/// On failure: spawn/wait I/O errors, or [`error.StreamTooLong`] if a cap is exceeded.
pub fn runHook(
    allocator: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_bytes: []const u8,
    max_stdout_bytes: usize,
    max_stderr_bytes: usize,
    timeout: Io.Timeout,
) RunHookError!RunHookResult {
    if (argv.len == 0) return error.InvalidArgv;

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    const stdin_w = child.stdin orelse return error.InvalidStdinPipe;
    try stdin_w.writeStreamingAll(io, stdin_bytes);
    stdin_w.close(io);
    child.stdin = null;

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_limit = Io.Limit.limited(max_stdout_bytes);
    const stderr_limit = Io.Limit.limited(max_stderr_bytes);

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64 * 1024, timeout)) |_| {
        if (stdout_limit.toInt()) |lim| {
            if (stdout_reader.buffered().len > lim)
                return error.StreamTooLong;
        }
        if (stderr_limit.toInt()) |lim| {
            if (stderr_reader.buffered().len > lim)
                return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);

    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = term,
    };
}

test "runHook cat copies stdin to stdout" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const argv = &.{"/bin/cat"};
    const r = try runHook(alloc, io, argv, "{\"x\":1}\n", 1 * 1024 * 1024, 64 * 1024, .none);
    defer {
        alloc.free(r.stdout);
        alloc.free(r.stderr);
    }

    switch (r.term) {
        .exited => |c| try std.testing.expectEqual(@as(u8, 0), c),
        else => return error.BadTerm,
    }
    try std.testing.expectEqualStrings("{\"x\":1}\n", r.stdout);
}
