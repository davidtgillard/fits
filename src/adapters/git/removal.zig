//! Git CLI adapter for recording object removals (removal commit + `git_commit` ref).

const std = @import("std");
const vcs_removal = @import("../../domain/vcs_removal.zig");
const git_repo = @import("repo.zig");

const Io = std.Io;

/// Git-backed [`vcs_removal.VcsRemovalBackend`].
pub const GitRemovalBackend = struct {
    /// Creates a backend instance for use with [`asInterface`].
    pub fn init() GitRemovalBackend {
        return .{};
    }

    /// Exposes this value as a [`vcs_removal.VcsRemovalBackend`].
    pub fn asInterface(self: *GitRemovalBackend) vcs_removal.VcsRemovalBackend {
        return .{
            .context = self,
            .vtable = &.{
                .name = nameAdapter,
                .isAvailable = isAvailableAdapter,
                .recordRemoval = recordRemovalAdapter,
            },
        };
    }

    fn nameAdapter(context: *anyopaque) []const u8 {
        _ = context;
        return "git";
    }

    fn isAvailableAdapter(context: *anyopaque, io: Io, repo_root: []const u8) bool {
        _ = context;
        return git_repo.repoHasGit(io, repo_root);
    }

    fn recordRemovalAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        io: Io,
        repo_root: []const u8,
        paths: []const []const u8,
        message: []const u8,
    ) anyerror!vcs_removal.RemovalRecord {
        _ = context;
        if (paths.len == 0) return error.NothingToCommit;

        var rm_args = std.ArrayListUnmanaged([]const u8).empty;
        defer rm_args.deinit(allocator);
        try rm_args.append(allocator, "git");
        try rm_args.append(allocator, "-C");
        try rm_args.append(allocator, repo_root);
        try rm_args.append(allocator, "rm");
        try rm_args.append(allocator, "-r");
        try rm_args.append(allocator, "-f");
        try rm_args.append(allocator, "--");
        for (paths) |p| try rm_args.append(allocator, p);
        try runGitCheckedVoid(allocator, io, rm_args.items);

        try runGitCheckedVoid(allocator, io, &.{ "git", "-C", repo_root, "commit", "-m", message });

        const head = try runGitChecked(allocator, io, &.{ "git", "-C", repo_root, "rev-parse", "HEAD" });
        defer allocator.free(head);
        const sha = std.mem.trim(u8, head, " \t\r\n");
        const copy = try allocator.dupe(u8, sha);
        return .{ .git_commit = copy };
    }
};

fn runGit(io: Io, repo_root: []const u8, git_args: []const []const u8) ![]u8 {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(std.heap.page_allocator);
    try argv.append(std.heap.page_allocator, "git");
    try argv.append(std.heap.page_allocator, "-C");
    try argv.append(std.heap.page_allocator, repo_root);
    for (git_args) |a| try argv.append(std.heap.page_allocator, a);
    return runGitChecked(std.heap.page_allocator, io, argv.items);
}

fn runGitCheckedVoid(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const out = try runGitChecked(allocator, io, argv);
    defer allocator.free(out);
}

fn runGitChecked(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .inherit,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("command failed (exit {d}): {s}", .{ code, result.stderr });
            allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.GitCommandFailed;
        },
    }

    return result.stdout;
}
