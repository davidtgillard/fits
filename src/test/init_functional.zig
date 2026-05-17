//! Functional tests for [`init_repo`](../app/init_repo.zig).

const std = @import("std");
const init_repo = @import("../app/init_repo.zig");
const gitignore = @import("../adapters/git/gitignore.zig");

const no_interactive: init_repo.InitOptions = .{ .no_interactive = true };

fn initGitRepo(alloc: std.mem.Allocator, io: std.Io, repo_abs: []const u8) !void {
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "git", "-C", repo_abs, "init" },
        .cwd = .inherit,
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitCommandFailed,
        else => return error.GitCommandFailed,
    }
}

test "init creates registry links config and cache" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try init_repo.run(alloc, std.testing.io, repo_abs, no_interactive);

    const reg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "registry.json" });
    defer alloc.free(reg_sub);
    const reg_contents = try tmp.dir.readFileAlloc(std.testing.io, reg_sub, alloc, .unlimited);
    defer alloc.free(reg_contents);
    try std.testing.expect(std.mem.indexOf(u8, reg_contents, "\"node_types\": []") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg_contents, "\"link_types\": []") != null);

    const links_sub = try std.fs.path.join(alloc, &.{ "repo", "links", "links.jsonc" });
    defer alloc.free(links_sub);
    const links_contents = try tmp.dir.readFileAlloc(std.testing.io, links_sub, alloc, .unlimited);
    defer alloc.free(links_contents);
    try std.testing.expect(std.mem.indexOf(u8, links_contents, "\"links\": []") != null);

    const cfg_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "fits_config.toml" });
    defer alloc.free(cfg_sub);
    const cfg_contents = try tmp.dir.readFileAlloc(std.testing.io, cfg_sub, alloc, .unlimited);
    defer alloc.free(cfg_contents);
    try std.testing.expect(std.mem.indexOf(u8, cfg_contents, "update_check_time_period = 86400") != null);

    const cache_sub = try std.fs.path.join(alloc, &.{ "repo", ".fits", "cache" });
    defer alloc.free(cache_sub);
    const cache_st = try tmp.dir.statFile(std.testing.io, cache_sub, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, cache_st.kind);
}

test "init twice returns AlreadyInitialized" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");

    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try init_repo.run(alloc, std.testing.io, repo_abs, no_interactive);
    try std.testing.expectError(error.AlreadyInitialized, init_repo.run(alloc, std.testing.io, repo_abs, no_interactive));
}

test "init edit-gitignore flag appends cache line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    const opts: init_repo.InitOptions = .{
        .no_interactive = true,
        .edit_gitignore = true,
    };
    try init_repo.run(alloc, std.testing.io, repo_abs, opts);

    const ign_sub = try std.fs.path.join(alloc, &.{ "repo", ".gitignore" });
    defer alloc.free(ign_sub);
    const ign = try tmp.dir.readFileAlloc(std.testing.io, ign_sub, alloc, .unlimited);
    defer alloc.free(ign);
    try std.testing.expect(std.mem.indexOf(u8, ign, gitignore.cache_ignore_line) != null);
}

test "init edit-gitignore is idempotent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    const opts: init_repo.InitOptions = .{
        .no_interactive = true,
        .edit_gitignore = true,
    };
    try init_repo.run(alloc, std.testing.io, repo_abs, opts);
    try gitignore.ensureCacheEntry(std.testing.io, alloc, repo_abs);

    const ign_sub = try std.fs.path.join(alloc, &.{ "repo", ".gitignore" });
    defer alloc.free(ign_sub);
    const ign = try tmp.dir.readFileAlloc(std.testing.io, ign_sub, alloc, .unlimited);
    defer alloc.free(ign);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, ign, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), gitignore.cache_ignore_line)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "init init-git flag creates git directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    const opts: init_repo.InitOptions = .{
        .no_interactive = true,
        .init_git = true,
    };
    try init_repo.run(alloc, std.testing.io, repo_abs, opts);

    const git_sub = try std.fs.path.join(alloc, &.{ "repo", ".git" });
    defer alloc.free(git_sub);
    _ = try tmp.dir.statFile(std.testing.io, git_sub, .{});
}

test "init init-git no-op when git already exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try initGitRepo(alloc, std.testing.io, repo_abs);

    const opts: init_repo.InitOptions = .{
        .no_interactive = true,
        .init_git = true,
    };
    try init_repo.run(alloc, std.testing.io, repo_abs, opts);
}

test "init auto gitignore without git when interactive defaults" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    const repo_abs_z = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo_abs_z);
    const repo_abs: []const u8 = std.mem.sliceTo(repo_abs_z, 0);

    try std.testing.expectEqual(true, init_repo.resolveEditGitignore(.{}, false, false).?);
    try init_repo.run(alloc, std.testing.io, repo_abs, .{ .no_interactive = true, .edit_gitignore = true });
}
