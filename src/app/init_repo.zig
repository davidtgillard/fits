//! CLI use-case: strict greenfield scaffold for `.fits/`, registry, links index, cache, and repo-local config.
//! Optionally initializes git and updates `.gitignore` for the fits cache directory.

const builtin = @import("builtin");
const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const fits_config = @import("../adapters/fs/fits_config.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const fits_cache = @import("../adapters/cache/fits_cache.zig");
const git_repo = @import("../adapters/git/repo.zig");
const gitignore = @import("../adapters/git/gitignore.zig");
const prompt = @import("../cli/prompt.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// Default repository root (current working directory), consistent with other CLI use-cases.
pub const default_repo_root: []const u8 = ".";

/// Flags and overrides for optional git and `.gitignore` steps after scaffold.
pub const InitOptions = struct {
    no_interactive: bool = false,
    init_git: ?bool = null,
    edit_gitignore: ?bool = null,
};

const minimal_config_body =
    \\update_check_time_period = 86400
    \\
;

/// Initializes a fits-managed repository layout under `repo_root`.
///
/// Fails with `error.AlreadyInitialized` when `.fits/registry.json` or `links/links.jsonc` already exists.
///
/// Parameters:
/// - `allocator`: Path joins and file buffers.
/// - `io`: Process I/O for filesystem operations and optional prompts.
/// - `repo_root`: Repository root (relative or absolute path string).
/// - `options`: Interactive git init and `.gitignore` behavior.
///
/// Returns: `void` on success; `error.AlreadyInitialized` when scaffold files already exist; other I/O or allocation errors as propagated.
pub fn run(allocator: std.mem.Allocator, io: Io, repo_root: []const u8, options: InitOptions) !void {
    try runScaffold(allocator, io, repo_root);

    const had_git = git_repo.repoHasGit(io, repo_root);
    const can_prompt = prompt.canPrompt(io, options.no_interactive);

    const do_init_git = resolveInitGit(options, had_git, can_prompt) orelse
        try prompt.askYesNo(io, allocator, "Initialize a git repository in this directory?");
    if (do_init_git and !had_git) {
        try git_repo.initRepo(allocator, io, repo_root);
    } else if (do_init_git and had_git and !builtin.is_test) {
        std.debug.print("fits init: git repository already exists\n", .{});
    }

    const do_edit_gitignore = resolveEditGitignore(options, had_git, can_prompt) orelse
        try prompt.askYesNo(io, allocator, "Add .fits/cache/ to .gitignore?");
    if (do_edit_gitignore) {
        try gitignore.ensureCacheEntry(io, allocator, repo_root);
    }
}

/// Resolves whether to run `git init` before optional prompting.
///
/// Returns: a definite choice, or `null` when the caller should prompt.
pub fn resolveInitGit(options: InitOptions, had_git: bool, can_prompt: bool) ?bool {
    if (had_git) return false;
    if (options.init_git) |v| return v;
    if (!can_prompt) return false;
    return null;
}

/// Resolves whether to append the cache line to `.gitignore` before optional prompting.
///
/// Returns: a definite choice, or `null` when the caller should prompt.
pub fn resolveEditGitignore(options: InitOptions, had_git: bool, can_prompt: bool) ?bool {
    if (options.edit_gitignore) |v| return v;
    if (!had_git) return true;
    if (!can_prompt) return false;
    return null;
}

fn runScaffold(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !void {
    const cwd = Dir.cwd();

    const reg_path = try fits_registry.joinRegistryPath(allocator, repo_root);
    defer allocator.free(reg_path);
    if (pathExistsFile(cwd, io, reg_path)) {
        const disp = try fits_registry.formatRegistryRelPath(allocator, repo_root);
        defer allocator.free(disp);
        if (!builtin.is_test) std.debug.print("fits init: already initialized ({s} exists)\n", .{disp});
        return error.AlreadyInitialized;
    }

    const links_path = try links_index.joinLinksAbsPath(allocator, repo_root);
    defer allocator.free(links_path);
    if (pathExistsFile(cwd, io, links_path)) {
        const disp = try links_index.formatLinksRelPath(allocator, repo_root);
        defer allocator.free(disp);
        if (!builtin.is_test) std.debug.print(
            "fits init: already initialized ({s} exists)\n",
            .{disp},
        );
        return error.AlreadyInitialized;
    }

    var reg: fits_registry.Registry = .{ .allocator = allocator };
    defer reg.deinit();
    try reg.save(io, repo_root);

    const cfg_path = try fits_config.joinRepoFitsConfigPath(allocator, repo_root);
    defer allocator.free(cfg_path);
    if (!pathExistsFile(cwd, io, cfg_path)) {
        try writeFileAtomic(cwd, io, allocator, cfg_path, minimal_config_body);
    }

    const cache_rel = try std.fs.path.join(allocator, &.{
        repo_root,
        fits_registry.fits_dir_name,
        fits_cache.cache_dir_name,
    });
    defer allocator.free(cache_rel);
    try cwd.createDirPath(io, cache_rel);

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

test "resolveInitGit" {
    const opts: InitOptions = .{};
    try std.testing.expectEqual(false, resolveInitGit(opts, true, true).?);
    try std.testing.expectEqual(false, resolveInitGit(opts, false, false).?);
    try std.testing.expect(resolveInitGit(opts, false, true) == null);
    try std.testing.expectEqual(true, resolveInitGit(.{ .init_git = true }, false, false).?);
}

test "resolveEditGitignore" {
    const opts: InitOptions = .{};
    try std.testing.expectEqual(true, resolveEditGitignore(opts, false, false).?);
    try std.testing.expectEqual(false, resolveEditGitignore(opts, true, false).?);
    try std.testing.expect(resolveEditGitignore(opts, true, true) == null);
    try std.testing.expectEqual(true, resolveEditGitignore(.{ .edit_gitignore = true }, true, false).?);
}
