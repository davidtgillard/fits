//! Git `diff` path narrowing for incremental hook runs.
//! Does not read the working tree except checking for `.git`; all paths come from a subprocess.

const std = @import("std");
const links_index = @import("../fs/links_index.zig");

const Io = std.Io;

/// Paths that differ from `HEAD`, used to skip unchanged graph objects (nodes and links) when incremental hooks run.
///
/// When [`have_git`](GitDirtyState.have_git) is false (no repo, `git` failed, or nonzero exit), callers
/// should not filter by git and rely on fingerprinting only.
pub const GitDirtyState = struct {
    /// True when `git diff HEAD --name-only` completed with exit 0.
    have_git: bool = false,
    /// Node instance ids under `objects/<id>/`.
    node_ids: std.StringHashMapUnmanaged(void) = .empty,
    /// Link instance ids for paths under `relations/<id>/` (not the links index file).
    link_folder_ids: std.StringHashMapUnmanaged(void) = .empty,
    /// The links index file [`relations/links.jsonc`](links_index.links_file_name) is in the diff.
    links_index_dirty: bool = false,

    /// Frees hash map keys duplicated during [`load`].
    ///
    /// Parameters:
    /// - `self`: State populated by [`load`].
    /// - `allocator`: Same allocator used for map keys.
    pub fn deinit(self: *GitDirtyState, allocator: std.mem.Allocator) void {
        var it = self.node_ids.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        self.node_ids.deinit(allocator);
        var it2 = self.link_folder_ids.iterator();
        while (it2.next()) |kv| allocator.free(kv.key_ptr.*);
        self.link_folder_ids.deinit(allocator);
        self.* = .{};
    }
};

/// Loads changed paths vs `HEAD` for narrowing incremental hook batches.
///
/// Parameters:
/// - `allocator`: Duplicates ids inserted into the returned maps.
/// - `io`: Process I/O for `git`.
/// - `repo_root`: Passed to `git -C`.
///
/// Returns: [`GitDirtyState`] with `have_git == false` when `.git` is missing, `git` fails, or diff exits nonzero.
pub fn load(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !GitDirtyState {
    if (!repoHasGit(io, repo_root)) return .{};

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo_root, "diff", "HEAD", "--name-only" },
        .cwd = .inherit,
    }) catch return .{};
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |c| if (c != 0) return .{},
        else => return .{},
    }

    var state = GitDirtyState{ .have_git = true };

    var lines = std.mem.splitAny(u8, result.stdout, "\r\n");
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) continue;

        const objects_prefix = "objects/";
        if (std.mem.startsWith(u8, t, objects_prefix)) {
            const rest = t[objects_prefix.len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const id_slice = rest[0..slash];
            if (id_slice.len == 0) continue;
            const owned = try allocator.dupe(u8, id_slice);
            errdefer allocator.free(owned);
            try state.node_ids.put(allocator, owned, {});
            continue;
        }

        const relations_prefix = "relations/";
        if (std.mem.startsWith(u8, t, relations_prefix)) {
            const rest = t[relations_prefix.len..];
            const seg_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const first = rest[0..seg_end];
            if (first.len == 0) continue;
            if (std.mem.eql(u8, first, links_index.links_file_name)) {
                state.links_index_dirty = true;
                continue;
            }
            const owned = try allocator.dupe(u8, first);
            errdefer allocator.free(owned);
            try state.link_folder_ids.put(allocator, owned, {});
        }
    }

    return state;
}

fn repoHasGit(io: Io, repo_root: []const u8) bool {
    const git_path = std.fs.path.join(std.heap.page_allocator, &.{ repo_root, ".git" }) catch return false;
    defer std.heap.page_allocator.free(git_path);
    _ = Io.Dir.cwd().statFile(io, git_path, .{}) catch return false;
    return true;
}
