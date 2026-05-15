//! CLI use-case: strict greenfield scaffold for `.fits/`, registry, links index, cache, and repo-local config.

const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const fits_config = @import("../adapters/fs/fits_config.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const latticedb_cache = @import("../adapters/cache/latticedb_cache.zig");
const tombstone_cache = @import("../adapters/cache/tombstone_cache.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// Default repository root (current working directory), consistent with other CLI use-cases.
pub const default_repo_root: []const u8 = ".";

const minimal_config_body =
    \\update_check_time_period = 86400
    \\
;

/// Initializes a fits-managed repository layout under `repo_root`.
///
/// Fails with `error.AlreadyInitialized` when `.fits/registry.json` or `relations/links.jsonc` already exists.
///
/// Parameters:
/// - `allocator`: Path joins and file buffers.
/// - `io`: Process I/O for filesystem operations.
/// - `repo_root`: Repository root (relative or absolute path string).
///
/// Returns: `void` on success; `error.AlreadyInitialized` when scaffold files already exist; other I/O or allocation errors as propagated.
pub fn run(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !void {
    const cwd = Dir.cwd();

    const reg_path = try fits_registry.joinRegistryPath(allocator, repo_root);
    defer allocator.free(reg_path);
    if (pathExistsFile(cwd, io, reg_path)) {
        const disp = try fits_registry.formatRegistryRelPath(allocator, repo_root);
        defer allocator.free(disp);
        std.debug.print("fits init: already initialized ({s} exists)\n", .{disp});
        return error.AlreadyInitialized;
    }

    const links_path = try links_index.joinLinksAbsPath(allocator, repo_root);
    defer allocator.free(links_path);
    if (pathExistsFile(cwd, io, links_path)) {
        const disp = try links_index.formatLinksRelPath(allocator, repo_root);
        defer allocator.free(disp);
        std.debug.print(
            "fits init: already initialized ({s} exists)\n",
            .{disp},
        );
        return error.AlreadyInitialized;
    }

    var reg: fits_registry.Registry = .{ .allocator = allocator };
    defer reg.deinit();
    try reg.save(io, repo_root);

    try tombstone_cache.writeEmptyInitial(allocator, io, repo_root);

    const cfg_path = try fits_config.joinRepoFitsConfigPath(allocator, repo_root);
    defer allocator.free(cfg_path);
    if (!pathExistsFile(cwd, io, cfg_path)) {
        try writeFileAtomic(cwd, io, allocator, cfg_path, minimal_config_body);
    }

    const ldb_rel = try std.fs.path.join(allocator, &.{
        repo_root,
        fits_registry.fits_dir_name,
        latticedb_cache.latticedb_dir_name,
    });
    defer allocator.free(ldb_rel);
    try cwd.createDirPath(io, ldb_rel);

    try links_index.writeLinksAtomic(io, allocator, repo_root, &.{});
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
