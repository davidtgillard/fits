//! Functional tests for update config, cache, and mock update source.

const std = @import("std");
const fits_config = @import("../adapters/fs/fits_config.zig");
const fits_cache = @import("../adapters/cache/fits_cache.zig");
const github_release = @import("../adapters/github/release.zig");
const update_mod = @import("../app/update.zig");

test "fits_config load creates default period" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg_dir = "cfg/fits";
    try tmp.dir.createDirPath(std.testing.io, "cfg");
    try tmp.dir.createDirPath(std.testing.io, cfg_dir);

    const cfg_path = "cfg/fits/fits_config.toml";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = cfg_path,
        .data = "update_check_time_period = 3600\n",
    });

    const text = try tmp.dir.readFileAlloc(std.testing.io, cfg_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    const cfg = try fits_config.parseConfig(std.testing.allocator, text);
    try std.testing.expectEqual(@as(u64, 3600), cfg.update_check_time_period);
}

test "fits cache last update check" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = "repo/.fits/cache";
    try tmp.dir.createDirPath(std.testing.io, "repo/.fits");
    try tmp.dir.createDirPath(std.testing.io, store);

    var cache = try fits_cache.FitsCache.open(std.testing.allocator, std.testing.io, store);
    defer cache.deinit();

    try cache.setLastUpdateCheck(99_001);
    try std.testing.expectEqual(@as(i64, 99_001), try cache.getLastUpdateCheck());
}

test "commit comparison detects update" {
    const current = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const remote = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try std.testing.expect(update_mod.isRemoteCommitNewer(current, remote));
    try std.testing.expect(!update_mod.isRemoteCommitNewer(current, current));
}

test "mock source returns manifest" {
    var digest: [32]u8 = undefined;
    @memset(&digest, 0x01);
    var hex: [64]u8 = undefined;
    github_release.formatSha256Hex(digest, &hex);

    var mock: update_mod.MockSource = .{
        .manifest = .{
            .git_commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .sha256 = &hex,
        },
        .binary = &[_]u8{ 0x7f, 0x45, 0x4c, 0x46 },
    };

    const manifest = try mock.asInterface().fetchManifest(std.testing.allocator, std.testing.io);
    defer {
        std.testing.allocator.free(manifest.git_commit);
        std.testing.allocator.free(manifest.sha256);
    }
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", manifest.git_commit);
}
