//! Git `diff` path narrowing for incremental hook runs.
//! Does not read the working tree except checking for `.git`; all paths come from a subprocess.

const std = @import("std");
const links_index = @import("../fs/links_index.zig");
const path_layout = @import("../fs/path_layout.zig");

const Io = std.Io;

/// Paths that differ from `HEAD`, used to skip unchanged graph objects (nodes and links) when incremental hooks run.
///
/// When [`have_git`](GitDirtyState.have_git) is false (no repo, `git` failed, or nonzero exit), callers
/// should not filter by git and rely on fingerprinting only.
pub const GitDirtyState = struct {
    /// True when `git diff HEAD --name-only` completed with exit 0.
    have_git: bool = false,
    /// Node instance ids under type-scoped `nodes/.../<id>/`.
    node_ids: std.StringHashMapUnmanaged(void) = .empty,
    /// Link instance ids for paths under `links/<link_type>/<id>/`.
    link_folder_ids: std.StringHashMapUnmanaged(void) = .empty,
    /// The links index file `links/links.jsonc` is in the diff.
    links_index_dirty: bool = false,

    /// Frees hash map keys duplicated during [`load`].
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

        const nodes_prefix = path_layout.nodes_root ++ "/";
        if (std.mem.startsWith(u8, t, nodes_prefix)) {
            const rest = t[nodes_prefix.len..];
            if (extractCanonicalId(rest)) |id_slice| {
                const owned = try allocator.dupe(u8, id_slice);
                errdefer allocator.free(owned);
                try state.node_ids.put(allocator, owned, {});
            }
            continue;
        }

        const links_prefix = path_layout.links_root ++ "/";
        if (std.mem.startsWith(u8, t, links_prefix)) {
            const rest = t[links_prefix.len..];
            const seg_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const first = rest[0..seg_end];
            if (first.len == 0) continue;
            if (std.mem.eql(u8, first, links_index.links_file_name)) {
                state.links_index_dirty = true;
                continue;
            }
            // links/<link_type>/<link-id>/...
            const after_type = rest[seg_end..];
            if (after_type.len == 0 or after_type[0] != '/') continue;
            const id_rest = after_type[1..];
            const id_end = std.mem.indexOfScalar(u8, id_rest, '/') orelse id_rest.len;
            const link_id = id_rest[0..id_end];
            if (link_id.len == 0) continue;
            const owned = try allocator.dupe(u8, link_id);
            errdefer allocator.free(owned);
            try state.link_folder_ids.put(allocator, owned, {});
        }
    }

    return state;
}

/// Returns a canonical `{PREFIX}-{n}` slice from a path under `nodes/`, or null.
fn extractCanonicalId(path_under_nodes: []const u8) ?[]const u8 {
    var segments = std.mem.splitScalar(u8, path_under_nodes, '/');
    while (segments.next()) |seg| {
        const dash = std.mem.indexOfScalar(u8, seg, '-') orelse continue;
        if (dash + 1 >= seg.len) continue;
        var i: usize = dash + 1;
        var digits: usize = 0;
        while (i < seg.len and std.ascii.isDigit(seg[i])) : (i += 1) digits += 1;
        if (digits == 0) continue;
        const end = dash + 1 + digits;
        if (end == seg.len or seg[end] == ' ') return seg[0..end];
    }
    return null;
}

fn repoHasGit(io: Io, repo_root: []const u8) bool {
    const git_path = std.fs.path.join(std.heap.page_allocator, &.{ repo_root, ".git" }) catch return false;
    defer std.heap.page_allocator.free(git_path);
    _ = Io.Dir.cwd().statFile(io, git_path, .{}) catch return false;
    return true;
}
