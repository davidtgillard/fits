//! Filesystem adapter: loads object bundles from the repo working tree.

const std = @import("std");
const graph = @import("../../domain/graph.zig");
const git_ignore = @import("../git/ignore.zig");

/// Loads [`ObjectBundle`](graph.ObjectBundle) values from disk, respecting ignore rules.
pub const Loader = struct {
    /// Used to skip paths ignored by git-style rules.
    ignore_matcher: git_ignore.IgnoreMatcher,

    /// Constructs a loader with the given ignore matcher.
    ///
    /// Parameters:
    /// - `ignore_matcher`: Rules applied when scanning paths (stub until implemented).
    ///
    /// Returns: a [`Loader`] configured with `ignore_matcher`.
    pub fn init(ignore_matcher: git_ignore.IgnoreMatcher) Loader {
        return .{
            .ignore_matcher = ignore_matcher,
        };
    }

    /// Scans `repo_root`/`objects_dir` for object folders and returns owned bundles.
    ///
    /// Parameters:
    /// - `self`: Loader state (`ignore_matcher` reserved for future walks).
    /// - `allocator`: Used to allocate the returned slice (and eventually file contents).
    /// - `repo_root`: Absolute or relative repository root path.
    /// - `objects_dir`: Directory name or relative path under `repo_root` containing objects.
    ///
    /// Returns: a slice of bundles allocated with `allocator` (possibly empty). Caller must `allocator.free` the slice.
    /// On failure: `error.OutOfMemory` or future I/O errors once implemented.
    pub fn loadObjectBundles(
        self: Loader,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        objects_dir: []const u8,
    ) ![]graph.ObjectBundle {
        _ = self;
        _ = repo_root;
        _ = objects_dir;

        // Stub: returns empty until walk + id resolution + ignore filtering exist.
        return allocator.alloc(graph.ObjectBundle, 0);
    }
};
