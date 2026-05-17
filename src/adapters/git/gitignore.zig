//! Append fits cache paths to `.gitignore` at the adapter boundary.

const std = @import("std");

const Io = std.Io;
const Dir = Io.Dir;

/// `.gitignore` line that excludes the machine-local fits cache directory.
pub const cache_ignore_line: []const u8 = ".fits/cache/";

/// Appends [`cache_ignore_line`] to `repo_root/.gitignore` when not already present.
///
/// Parameters:
/// - `io`: Process I/O for read/write.
/// - `allocator`: Path joins and file buffers.
/// - `repo_root`: Repository root containing `.gitignore`.
///
/// Returns: `void` on success; propagated I/O or allocation errors.
pub fn ensureCacheEntry(io: Io, allocator: std.mem.Allocator, repo_root: []const u8) !void {
    const ignore_path = try std.fs.path.join(allocator, &.{ repo_root, ".gitignore" });
    defer allocator.free(ignore_path);

    const cwd = Dir.cwd();
    var existing: []const u8 = "";
    var existing_owned = false;
    defer if (existing_owned) allocator.free(existing);

    if (pathExistsFile(cwd, io, ignore_path)) {
        existing = try cwd.readFileAlloc(io, ignore_path, allocator, .unlimited);
        existing_owned = true;
        if (fileHasCacheLine(existing)) return;
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    if (existing.len != 0) {
        try body.appendSlice(allocator, existing);
        if (existing[existing.len - 1] != '\n') try body.append(allocator, '\n');
    }
    try body.appendSlice(allocator, cache_ignore_line);
    try body.append(allocator, '\n');

    try writeFileAtomic(cwd, io, allocator, ignore_path, body.items);
}

fn fileHasCacheLine(contents: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, cache_ignore_line) or
            std.mem.eql(u8, trimmed, ".fits/cache"))
        {
            return true;
        }
    }
    return false;
}

fn pathExistsFile(cwd: Dir, io: Io, path: []const u8) bool {
    const st = cwd.statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn writeFileAtomic(cwd: Dir, io: Io, allocator: std.mem.Allocator, final_path: []const u8, body: []const u8) !void {
    const tmp_path = try std.mem.concat(allocator, u8, &.{ final_path, ".tmp" });
    defer allocator.free(tmp_path);

    {
        var out = try cwd.createFile(io, tmp_path, .{ .read = false, .truncate = true, .exclusive = false });
        defer out.close(io);
        try out.writeStreamingAll(io, body);
        try out.sync(io);
    }

    try cwd.rename(tmp_path, cwd, final_path, io);
}
