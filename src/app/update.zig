//! CLI use-case: check for and apply self-updates from the rolling `dev` GitHub release.

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const fits_config = @import("../adapters/fs/fits_config.zig");
const fits_cache = @import("../adapters/cache/fits_cache.zig");
const github_release = @import("../adapters/github/release.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// Type-erased source for update metadata and binaries (enables tests without network).
pub const UpdateSource = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fetch_manifest: *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: Io) anyerror!github_release.Manifest,
        download_binary: *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: Io) anyerror![]u8,
    };

    pub fn fetchManifest(self: UpdateSource, allocator: std.mem.Allocator, io: Io) !github_release.Manifest {
        return self.vtable.fetch_manifest(self.context, allocator, io);
    }

    pub fn downloadBinary(self: UpdateSource, allocator: std.mem.Allocator, io: Io) ![]u8 {
        return self.vtable.download_binary(self.context, allocator, io);
    }
};

/// Live GitHub `dev` release backend.
pub const GithubDevSource = struct {
    environ: *const std.process.Environ.Map,

    pub fn asInterface(self: *GithubDevSource) UpdateSource {
        return .{
            .context = self,
            .vtable = &.{
                .fetch_manifest = manifestAdapter,
                .download_binary = binaryAdapter,
            },
        };
    }

    fn manifestAdapter(context: *anyopaque, allocator: std.mem.Allocator, io: Io) !github_release.Manifest {
        const self: *GithubDevSource = @ptrCast(@alignCast(context));
        return github_release.fetchDevManifest(allocator, io, self.environ);
    }

    fn binaryAdapter(context: *anyopaque, allocator: std.mem.Allocator, io: Io) ![]u8 {
        const self: *GithubDevSource = @ptrCast(@alignCast(context));
        return github_release.downloadDevBinary(allocator, io, self.environ);
    }
};

pub const CheckOptions = struct {
    quiet: bool = false,
    /// When true, persist `last_update_check` after a successful fetch.
    record_check_time: bool = true,
};

/// Returns embedded build commit, or empty for local builds.
pub fn embeddedGitCommit() []const u8 {
    return build_options.git_commit;
}

pub fn isUpdatableBuild() bool {
    return embeddedGitCommit().len == 40;
}

/// Returns true when `remote` differs from `current` (both full 40-char SHAs).
pub fn isRemoteCommitNewer(current: []const u8, remote: []const u8) bool {
    return !std.mem.eql(u8, current, remote);
}

/// Prints build version information.
pub fn runVersion() void {
    const commit = embeddedGitCommit();
    if (commit.len == 0) {
        std.debug.print("fits unknown (local build)\n", .{});
    } else {
        std.debug.print("fits {s}\n", .{commit});
    }
    std.debug.print("update source: {s}/{s} tag dev\n", .{ build_options.github_owner, build_options.github_repo });
}

/// Checks whether a newer `dev` release exists.
pub fn runCheck(
    allocator: std.mem.Allocator,
    io: Io,
    source: UpdateSource,
    cache: *fits_cache.FitsCache,
    opts: CheckOptions,
) !void {
    if (!isUpdatableBuild()) {
        if (!opts.quiet) std.debug.print("fits was built from source and cannot self-update\n", .{});
        return error.NotUpdatable;
    }

    const manifest = try source.fetchManifest(allocator, io);
    defer {
        allocator.free(manifest.git_commit);
        allocator.free(manifest.sha256);
    }

    if (opts.record_check_time) {
        try cache.setLastUpdateCheck(unixNow(io));
    }

    const current = embeddedGitCommit();
    if (!isRemoteCommitNewer(current, manifest.git_commit)) {
        if (!opts.quiet) std.debug.print("fits is up to date ({s})\n", .{current});
        return;
    }

    if (!opts.quiet) {
        std.debug.print("update available: {s} -> {s}\n", .{ current, manifest.git_commit });
        std.debug.print("run: fits update\n", .{});
    } else {
        std.debug.print("fits: update available ({s} -> {s}). Run: fits update\n", .{ current, manifest.git_commit });
    }
    return error.UpdateAvailable;
}

/// Downloads and installs a newer binary when available.
pub fn runApply(
    allocator: std.mem.Allocator,
    io: Io,
    source: UpdateSource,
    cache: *fits_cache.FitsCache,
) !void {
    if (!isUpdatableBuild()) {
        std.debug.print("fits was built from source and cannot self-update\n", .{});
        return error.NotUpdatable;
    }

    const manifest = try source.fetchManifest(allocator, io);
    defer {
        allocator.free(manifest.git_commit);
        allocator.free(manifest.sha256);
    }

    try cache.setLastUpdateCheck(unixNow(io));

    const current = embeddedGitCommit();
    if (!isRemoteCommitNewer(current, manifest.git_commit)) {
        std.debug.print("fits is up to date ({s})\n", .{current});
        return;
    }

    const binary = try source.downloadBinary(allocator, io);
    defer allocator.free(binary);

    try verifySha256(binary, manifest.sha256);
    try replaceExecutable(io, allocator, binary);

    std.debug.print("updated fits to {s}\n", .{manifest.git_commit});
}

/// Quiet background check invoked from a detached child process.
pub fn runBackgroundCheck(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    source: UpdateSource,
) !void {
    const store_dir = try fits_cache.FitsCache.resolveStoreDir(allocator, io, environ, ".");
    defer allocator.free(store_dir);

    var cache = try fits_cache.FitsCache.open(allocator, io, store_dir);
    defer cache.deinit();

    runCheck(allocator, io, source, &cache, .{ .quiet = true, .record_check_time = true }) catch |err| switch (err) {
        error.UpdateAvailable => {},
        error.NotUpdatable => {},
        else => return err,
    };
}

/// Returns whether a detached background check should be spawned.
pub fn shouldSpawnBackgroundCheck(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !bool {
    if (builtin.is_test) return false;
    if (!isUpdatableBuild()) return false;
    if (environ.get("FITS_NO_UPDATE_CHECK")) |_| return false;

    const cfg = try fits_config.loadOrCreateDefault(allocator, io, environ);
    const store_dir = try fits_cache.FitsCache.resolveStoreDir(allocator, io, environ, ".");
    defer allocator.free(store_dir);

    var cache = try fits_cache.FitsCache.open(allocator, io, store_dir);
    defer cache.deinit();

    const last = try cache.getLastUpdateCheck();
    return fits_config.shouldRunBackgroundCheck(unixNow(io), cfg.update_check_time_period, last);
}

fn unixNow(io: Io) i64 {
    return Io.Timestamp.toSeconds(Io.Clock.Timestamp.now(io, .real).raw);
}

/// Spawns a detached `fits update --background` child.
pub fn spawnBackgroundCheck(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !void {
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);

    const argv = [_][]const u8{ exe, "update", "--background" };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    for (environ.keys()) |key| {
        const value = environ.get(key) orelse continue;
        try env_map.put(key, value);
    }
    try env_map.put("FITS_NO_UPDATE_CHECK", "1");

    _ = try std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn verifySha256(data: []const u8, expected_hex: []const u8) !void {
    const expected = try github_release.parseSha256Hex(expected_hex);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    if (!std.mem.eql(u8, &digest, &expected)) {
        std.debug.print("error: downloaded binary SHA-256 does not match manifest\n", .{});
        return error.ChecksumMismatch;
    }
}

fn replaceExecutable(io: Io, allocator: std.mem.Allocator, binary: []const u8) !void {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);

    const new_path = try std.mem.concat(allocator, u8, &.{ exe_path, ".new" });
    defer allocator.free(new_path);

    const cwd = Dir.cwd();
    {
        var out = try cwd.createFile(io, new_path, .{ .read = false, .truncate = true, .exclusive = false });
        defer out.close(io);
        try out.writeStreamingAll(io, binary);
        try out.sync(io);
    }

    const st = cwd.statFile(io, exe_path, .{}) catch return error.ExecutableNotFound;
    try cwd.setFilePermissions(io, new_path, st.permissions, .{});

    cwd.rename(new_path, cwd, exe_path, io) catch |err| {
        cwd.deleteFile(io, new_path) catch {};
        return err;
    };
}

/// In-memory mock for tests.
pub const MockSource = struct {
    manifest: github_release.Manifest,
    binary: []const u8,

    pub fn asInterface(self: *MockSource) UpdateSource {
        return .{
            .context = self,
            .vtable = &.{
                .fetch_manifest = mockManifest,
                .download_binary = mockBinary,
            },
        };
    }

    fn mockManifest(context: *anyopaque, allocator: std.mem.Allocator, io: Io) !github_release.Manifest {
        _ = io;
        const self: *MockSource = @ptrCast(@alignCast(context));
        const git_commit = try allocator.dupe(u8, self.manifest.git_commit);
        errdefer allocator.free(git_commit);
        const sha256 = try allocator.dupe(u8, self.manifest.sha256);
        return .{ .git_commit = git_commit, .sha256 = sha256 };
    }

    fn mockBinary(context: *anyopaque, allocator: std.mem.Allocator, io: Io) ![]u8 {
        _ = io;
        const self: *MockSource = @ptrCast(@alignCast(context));
        return try allocator.dupe(u8, self.binary);
    }
};

pub const NotUpdatable = error.NotUpdatable;
pub const UpdateAvailable = error.UpdateAvailable;
pub const ChecksumMismatch = error.ChecksumMismatch;

/// True when the CLI already printed a user-facing message for this update error.
pub fn isReportedUpdateError(err: anyerror) bool {
    return switch (err) {
        NotUpdatable,
        ChecksumMismatch,
        github_release.HttpError,
        github_release.ReleaseNotFound,
        github_release.AssetNotFound,
        github_release.InvalidManifest,
        => true,
        else => false,
    };
}
