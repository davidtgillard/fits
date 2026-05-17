//! Git repository detection and initialization at the adapter boundary.

const std = @import("std");

const Io = std.Io;

/// True when `repo_root` itself is a git repository (not merely inside a parent work tree).
///
/// Parameters:
/// - `io`: Process I/O for filesystem stat.
/// - `repo_root`: Repository root path.
///
/// Returns: `true` when `repo_root/.git` exists.
pub fn repoHasGit(io: Io, repo_root: []const u8) bool {
    const git_path = std.fs.path.join(std.heap.page_allocator, &.{ repo_root, ".git" }) catch return false;
    defer std.heap.page_allocator.free(git_path);
    _ = Io.Dir.cwd().statFile(io, git_path, .{}) catch return false;
    return true;
}

/// Runs `git init` in `repo_root`.
///
/// Parameters:
/// - `allocator`: Subprocess output buffers.
/// - `io`: Process I/O.
/// - `repo_root`: Directory to initialize as a git repository.
///
/// Returns: `void` on success, or `error.GitCommandFailed` when `git` exits non-zero.
pub fn initRepo(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo_root, "init" },
        .cwd = .inherit,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
}
