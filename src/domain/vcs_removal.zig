//! Port for recording object removals in version control (VCS-agnostic domain boundary).

const std = @import("std");

const Io = std.Io;

/// VCS-specific references returned after a successful removal recording.
pub const RemovalRecord = struct {
    /// Git removal commit object name (40-char SHA-1), when git backend ran.
    git_commit: ?[]const u8 = null,
};

/// Type-erased backend that stages/commits or equivalent for a filesystem removal.
pub const VcsRemovalBackend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// Virtual methods for [`VcsRemovalBackend`].
    pub const VTable = struct {
        /// Stable backend id (e.g. `"git"`).
        name: *const fn (context: *anyopaque) []const u8,
        /// Returns whether this backend applies at `repo_root`.
        isAvailable: *const fn (context: *anyopaque, io: Io, repo_root: []const u8) bool,
        /// Records removal of `paths` (relative to repo root) and returns refs for the tombstone.
        recordRemoval: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            io: Io,
            repo_root: []const u8,
            paths: []const []const u8,
            message: []const u8,
        ) anyerror!RemovalRecord,
    };

    /// Backend identifier string.
    pub fn name(self: VcsRemovalBackend) []const u8 {
        return self.vtable.name(self.context);
    }

    /// Returns `true` when this backend can run at `repo_root`.
    pub fn isAvailable(self: VcsRemovalBackend, io: Io, repo_root: []const u8) bool {
        return self.vtable.isAvailable(self.context, io, repo_root);
    }

    /// Invokes the backend removal workflow.
    pub fn recordRemoval(
        self: VcsRemovalBackend,
        allocator: std.mem.Allocator,
        io: Io,
        repo_root: []const u8,
        paths: []const []const u8,
        message: []const u8,
    ) !RemovalRecord {
        return self.vtable.recordRemoval(self.context, allocator, io, repo_root, paths, message);
    }
};

/// Merges `b` into `a` (each backend may set its own fields).
pub fn mergeRemovalRecord(a: *RemovalRecord, b: RemovalRecord) void {
    if (b.git_commit) |c| a.git_commit = c;
}

/// Frees owned strings inside `record` (currently none from backends — SHAs are caller-owned dupes).
pub fn freeRemovalRecord(_: std.mem.Allocator, _: *RemovalRecord) void {}
