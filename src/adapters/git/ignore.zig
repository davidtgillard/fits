//! Git-oriented ignore matching (`.gitignore`, etc.) at the adapter boundary.

/// Decides whether a path relative to the repo should be excluded from FITS snapshots.
pub const IgnoreMatcher = struct {
    /// Repository root path used to resolve ignore files (implementation-defined).
    repo_root: []const u8,

    /// Creates a matcher rooted at `repo_root` (bytes as provided by the caller).
    ///
    /// Parameters:
    /// - `repo_root`: Path string stored for future ignore-file resolution (not copied; must outlive uses of the matcher if it points into ephemeral memory).
    ///
    /// Returns: an [`IgnoreMatcher`] storing the `repo_root` slice.
    pub fn init(repo_root: []const u8) IgnoreMatcher {
        return .{
            .repo_root = repo_root,
        };
    }

    /// Returns `true` if `relative_path` should be ignored when building bundles.
    ///
    /// Parameters:
    /// - `self`: Matcher state (uses `repo_root` once gitignore integration exists).
    /// - `relative_path`: Path relative to the repository root being scanned.
    ///
    /// Returns: `true` if the path should be excluded, `false` otherwise (stub always returns `false`).
    pub fn isIgnored(self: IgnoreMatcher, relative_path: []const u8) bool {
        _ = self;
        _ = relative_path;
        // Stub: always false until gitignore parsing is implemented.
        return false;
    }
};
