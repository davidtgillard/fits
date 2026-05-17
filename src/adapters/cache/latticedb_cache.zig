//! Local key-value cache under `.fits/latticedb/` (or `~/.fits/latticedb/` globally).
//! Minimal file-backed store until full LatticeDB integration.

const std = @import("std");
const fits_registry = @import("../fs/fits_registry.zig");
const fits_config = @import("../fs/fits_config.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// LatticeDB directory name inside `.fits/` or `~/.fits/`.
pub const latticedb_dir_name: []const u8 = "latticedb";

/// Cache key for last successful update check timestamp.
pub const last_update_check_key: []const u8 = "update:last_check";

/// Prefix for hook fingerprint keys (`hooks:node:…`, `hooks:link:…`).
pub const hook_fingerprint_prefix: []const u8 = "hooks:";

const value_size: usize = 8;

/// Key-value cache used to accelerate validation and hold machine-owned metadata.
pub const CacheStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (context: *anyopaque, key: []const u8, value: []const u8) anyerror!void,
        get: *const fn (context: *anyopaque, key: []const u8) anyerror!?[]const u8,
    };

    pub fn put(self: CacheStore, key: []const u8, value: []const u8) !void {
        return self.vtable.put(self.context, key, value);
    }

    pub fn get(self: CacheStore, key: []const u8) !?[]const u8 {
        return self.vtable.get(self.context, key);
    }
};

/// File-backed cache opened at `store_dir`.
pub const LatticeDbCache = struct {
    allocator: std.mem.Allocator,
    store_dir: []const u8,
    io: Io,

    pub fn init(allocator: std.mem.Allocator) LatticeDbCache {
        return .{
            .allocator = allocator,
            .store_dir = "",
            .io = undefined,
        };
    }

    /// Opens or creates the store at `store_dir` (caller-owned string is copied).
    pub fn open(allocator: std.mem.Allocator, io: Io, store_dir: []const u8) !LatticeDbCache {
        const owned = try allocator.dupe(u8, store_dir);
        errdefer allocator.free(owned);
        const cwd = Dir.cwd();
        try cwd.createDirPath(io, owned);
        return .{
            .allocator = allocator,
            .store_dir = owned,
            .io = io,
        };
    }

    pub fn deinit(self: *LatticeDbCache) void {
        if (self.store_dir.len != 0) self.allocator.free(self.store_dir);
        self.store_dir = "";
    }

    /// Resolves the LatticeDB store directory for `cwd_rel` (caller frees).
    pub fn resolveStoreDir(
        allocator: std.mem.Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
        cwd_rel: []const u8,
    ) ![]const u8 {
        const fits_rel = try std.fs.path.join(allocator, &.{ cwd_rel, fits_registry.fits_dir_name });
        defer allocator.free(fits_rel);

        const cwd = Dir.cwd();
        if (fits_config.fitsDirExists(cwd, io, fits_rel)) {
            return std.fs.path.join(allocator, &.{ fits_rel, latticedb_dir_name });
        }
        const home = environ.get("HOME") orelse return error.HomeNotSet;
        return std.fs.path.join(allocator, &.{ home, ".fits", latticedb_dir_name });
    }

    pub fn asInterface(self: *LatticeDbCache) CacheStore {
        return .{
            .context = self,
            .vtable = &.{
                .put = putAdapter,
                .get = getAdapter,
            },
        };
    }

    /// Reads last update check unix time; 0 when missing.
    pub fn getLastUpdateCheck(self: *LatticeDbCache) !i64 {
        const val = try self.get(last_update_check_key);
        if (val) |bytes| {
            defer self.allocator.free(bytes);
            if (bytes.len != value_size) return error.InvalidCacheValue;
            return std.mem.readInt(i64, bytes[0..value_size], .little);
        }
        return 0;
    }

    /// Persists last update check unix time.
    pub fn setLastUpdateCheck(self: *LatticeDbCache, unix_sec: i64) !void {
        var buf: [value_size]u8 = undefined;
        std.mem.writeInt(i64, &buf, unix_sec, .little);
        try self.put(last_update_check_key, &buf);
    }

    /// Deletes all cache files whose logical key starts with [`hook_fingerprint_prefix`].
    ///
    /// Parameters:
    /// - `self`: Open store at `store_dir`.
    ///
    /// Returns: void on success.
    /// On failure: I/O errors from directory iteration or delete.
    pub fn clearHookFingerprints(self: *LatticeDbCache) !void {
        const encoded_prefix = try encodeKey(self.allocator, hook_fingerprint_prefix);
        defer self.allocator.free(encoded_prefix);

        const cwd = Dir.cwd();
        var dir = cwd.openDir(self.io, self.store_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, encoded_prefix)) continue;
            const path = try std.fs.path.join(self.allocator, &.{ self.store_dir, entry.name });
            defer self.allocator.free(path);
            try cwd.deleteFile(self.io, path);
        }
    }

    pub fn put(self: *LatticeDbCache, key: []const u8, value: []const u8) !void {
        const path = try self.keyPath(key);
        defer self.allocator.free(path);
        const tmp_path = try std.mem.concat(self.allocator, u8, &.{ path, ".tmp" });
        defer self.allocator.free(tmp_path);

        const cwd = Dir.cwd();
        {
            var out = try cwd.createFile(self.io, tmp_path, .{ .read = false, .truncate = true, .exclusive = false });
            defer out.close(self.io);
            try out.writeStreamingAll(self.io, value);
            try out.sync(self.io);
        }
        try cwd.rename(tmp_path, cwd, path, self.io);
    }

    pub fn get(self: *LatticeDbCache, key: []const u8) !?[]u8 {
        const path = try self.keyPath(key);
        defer self.allocator.free(path);

        const cwd = Dir.cwd();
        const file = cwd.openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(self.io);

        const st = try file.stat(self.io);
        const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
        const buf = try self.allocator.alloc(u8, n);
        errdefer self.allocator.free(buf);
        const got = try file.readPositionalAll(self.io, buf, 0);
        if (got != n) return error.UnexpectedEndOfFile;
        return buf;
    }

    fn keyPath(self: *LatticeDbCache, key: []const u8) ![]const u8 {
        const safe = try encodeKey(self.allocator, key);
        defer self.allocator.free(safe);
        return std.fs.path.join(self.allocator, &.{ self.store_dir, safe });
    }

    fn encodeKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (key) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => try out.append(allocator, c),
                else => {
                    try out.append(allocator, '%');
                    var hex: [2]u8 = undefined;
                    _ = try std.fmt.bufPrint(&hex, "{x:0>2}", .{c});
                    try out.appendSlice(allocator, &hex);
                },
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn putAdapter(context: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
        const self: *LatticeDbCache = @ptrCast(@alignCast(context));
        return self.put(key, value);
    }

    fn getAdapter(context: *anyopaque, key: []const u8) anyerror!?[]const u8 {
        const self: *LatticeDbCache = @ptrCast(@alignCast(context));
        return self.get(key);
    }
};

test "put get roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = try std.fs.path.join(std.testing.allocator, &.{ "store", latticedb_dir_name });
    defer std.testing.allocator.free(store);
    try tmp.dir.createDirPath(std.testing.io, "store");
    try tmp.dir.createDirPath(std.testing.io, store);

    var cache = try LatticeDbCache.open(std.testing.allocator, std.testing.io, store);
    defer cache.deinit();

    try cache.setLastUpdateCheck(1_234_567);
    try std.testing.expectEqual(@as(i64, 1_234_567), try cache.getLastUpdateCheck());
}

test "encodeKey handles colon" {
    const enc = try LatticeDbCache.encodeKey(std.testing.allocator, "update:last_check");
    defer std.testing.allocator.free(enc);
    try std.testing.expect(std.mem.indexOf(u8, enc, "%") != null);
}

test "clearHookFingerprints removes hooks keys only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const store = try std.fs.path.join(std.testing.allocator, &.{ "store", latticedb_dir_name });
    defer std.testing.allocator.free(store);
    try tmp.dir.createDirPath(std.testing.io, "store");
    try tmp.dir.createDirPath(std.testing.io, store);

    var cache = try LatticeDbCache.open(std.testing.allocator, std.testing.io, store);
    defer cache.deinit();

    var hook_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &hook_buf, 42, .little);
    try cache.put("hooks:node:1:DS-1", &hook_buf);
    try cache.setLastUpdateCheck(99);

    try cache.clearHookFingerprints();
    try std.testing.expect((try cache.get("hooks:node:1:DS-1")) == null);
    try std.testing.expectEqual(@as(i64, 99), try cache.getLastUpdateCheck());
}
