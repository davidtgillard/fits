//! Machine-owned allocation state for FITS object IDs under `.fits/`.
//! Humans should not edit these files; the CLI owns create/update semantics,
//! tombstones deleted numeric suffixes (with optional VCS refs), and monotonic `next` counters.

const std = @import("std");

const Io = std.Io;
const Dir = Io.Dir;

/// Subdirectory under the repository root where FITS stores non-human metadata.
pub const fits_dir_name: []const u8 = ".fits";

/// Registry filename inside [`fits_dir_name`].
pub const registry_file_name: []const u8 = "registry.json";

/// Current on-disk registry schema version written by [`Registry.save`].
pub const registry_version: u32 = 2;

/// Git SHA-1 object name length in hex characters.
pub const git_commit_hex_len: usize = 40;

/// VCS-specific optional fields stored on a tombstone when recording removal.
pub const TombstoneRefs = struct {
    git_commit: ?[]const u8 = null,
};

/// A tombstoned numeric suffix for a prefix (must never be reissued).
pub const TombstoneEntry = struct {
    n: u64,
    git_commit: ?[]const u8 = null,
};

/// JSON tombstone row (v2).
const TombstoneJsonV2 = struct {
    n: u64,
    git_commit: ?[]const u8 = null,
};

/// JSON envelope written by [`Registry.save`].
const RegistryJsonV2 = struct {
    version: u32,
    kind: []const u8,
    prefixes: []PrefixJsonV2,
};

/// JSON prefix entry (v2).
const PrefixJsonV2 = struct {
    obj_prefix: []const u8,
    next: u64,
    tombstones: []TombstoneJsonV2 = &.{},
};

/// v1 on-disk shape (legacy `slug` field).
const RegistryJsonV1 = struct {
    version: u32,
    kind: []const u8,
    prefixes: []PrefixJsonV1,
};

const PrefixJsonV1 = struct {
    slug: []const u8,
    next: u64,
};

/// In-memory registry: per-prefix monotonic counter and tombstone list.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    prefixes: std.ArrayList(PrefixEntry) = .empty,

    /// Single prefix entry.
    pub const PrefixEntry = struct {
        obj_prefix: []const u8,
        next: u64,
        tombstones: std.ArrayList(TombstoneEntry) = .empty,
    };

    /// Frees duplicated strings and nested tombstone storage.
    pub fn deinit(self: *Registry) void {
        for (self.prefixes.items) |*entry| {
            self.allocator.free(entry.obj_prefix);
            for (entry.tombstones.items) |ts| {
                if (ts.git_commit) |c| self.allocator.free(c);
            }
            entry.tombstones.deinit(self.allocator);
        }
        self.prefixes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Loads registry from `repo_root`/.fits/registry.json`, or empty if missing.
    pub fn load(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !Registry {
        const path = try joinRegistryPath(allocator, repo_root);
        defer allocator.free(path);

        var file = openPath(io, path) catch |err| switch (err) {
            error.FileNotFound => return .{ .allocator = allocator },
            else => |e| return e,
        };
        defer file.close(io);

        const max_bytes = 16 * 1024 * 1024;
        const contents = try readFileAlloc(file, io, allocator, max_bytes);
        defer allocator.free(contents);

        const RegistryHeader = struct {
            version: u32,
            kind: []const u8,
        };

        var parsed_header = try std.json.parseFromSlice(RegistryHeader, allocator, contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_header.deinit();

        if (!std.mem.eql(u8, parsed_header.value.kind, "fits-registry-v1")) return error.InvalidRegistryKind;

        var reg: Registry = .{ .allocator = allocator };
        errdefer reg.deinit();

        switch (parsed_header.value.version) {
            1 => {
                var parsed_v1 = try std.json.parseFromSlice(RegistryJsonV1, allocator, contents, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed_v1.deinit();
                for (parsed_v1.value.prefixes) |pj| {
                    try mergePrefix(&reg, pj.slug, pj.next, &.{});
                }
            },
            2 => {
                var parsed_v2 = try std.json.parseFromSlice(RegistryJsonV2, allocator, contents, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed_v2.deinit();
                for (parsed_v2.value.prefixes) |pj| {
                    try mergePrefix(&reg, pj.obj_prefix, pj.next, pj.tombstones);
                }
            },
            else => return error.UnsupportedRegistryVersion,
        }

        for (reg.prefixes.items) |*entry| {
            sortTombstones(entry.tombstones.items);
        }
        sortPrefixes(reg.prefixes.items);
        return reg;
    }

    /// Writes registry atomically under `repo_root`/.fits/.
    pub fn save(self: *Registry, io: Io, repo_root: []const u8) !void {
        const cwd = Dir.cwd();
        const fits_path = try std.fs.path.join(self.allocator, &.{ repo_root, fits_dir_name });
        defer self.allocator.free(fits_path);
        try cwd.createDirPath(io, fits_path);

        const final_path = try joinRegistryPath(self.allocator, repo_root);
        defer self.allocator.free(final_path);

        const tmp_path = try std.mem.concat(self.allocator, u8, &.{ final_path, ".tmp" });
        defer self.allocator.free(tmp_path);

        sortPrefixes(self.prefixes.items);

        var prefixes_json = try self.allocator.alloc(PrefixJsonV2, self.prefixes.items.len);
        defer self.allocator.free(prefixes_json);

        var tombstone_bufs: std.ArrayList([]TombstoneJsonV2) = .empty;
        defer {
            for (tombstone_bufs.items) |buf| self.allocator.free(buf);
            tombstone_bufs.deinit(self.allocator);
        }

        for (self.prefixes.items, 0..) |e, i| {
            const ts_json = try self.allocator.alloc(TombstoneJsonV2, e.tombstones.items.len);
            try tombstone_bufs.append(self.allocator, ts_json);
            for (e.tombstones.items, 0..) |ts, j| {
                ts_json[j] = .{
                    .n = ts.n,
                    .git_commit = ts.git_commit,
                };
            }
            prefixes_json[i] = .{
                .obj_prefix = e.obj_prefix,
                .next = e.next,
                .tombstones = ts_json,
            };
        }

        const envelope = RegistryJsonV2{
            .version = registry_version,
            .kind = "fits-registry-v1",
            .prefixes = prefixes_json,
        };

        const json_text = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(envelope, .{ .whitespace = .indent_2 })});
        defer self.allocator.free(json_text);

        {
            var out = try cwd.createFile(io, tmp_path, .{ .read = false, .truncate = true, .exclusive = false });
            defer out.close(io);
            try out.writeStreamingAll(io, json_text);
            try out.sync(io);
        }

        try cwd.rename(tmp_path, cwd, final_path, io);
    }

    pub fn hasObjPrefix(self: *const Registry, obj_prefix: []const u8) bool {
        return findPrefixIndex(self.prefixes.items, obj_prefix) != null;
    }

    pub fn nextForObjPrefix(self: *const Registry, obj_prefix: []const u8) ?u64 {
        const idx = findPrefixIndex(self.prefixes.items, obj_prefix) orelse return null;
        return self.prefixes.items[idx].next;
    }

    /// Returns whether numeric suffix `n` is tombstoned for `obj_prefix`.
    pub fn isTombstoned(self: *const Registry, obj_prefix: []const u8, n: u64) bool {
        const idx = findPrefixIndex(self.prefixes.items, obj_prefix) orelse return false;
        return findTombstoneIndex(self.prefixes.items[idx].tombstones.items, n) != null;
    }

    /// Records a tombstone for issued suffix `n` with optional VCS refs.
    pub fn tombstoneNumeric(self: *Registry, obj_prefix: []const u8, n: u64, refs: TombstoneRefs) !void {
        const idx = findPrefixIndex(self.prefixes.items, obj_prefix) orelse return error.UnknownObjPrefix;
        if (findTombstoneIndex(self.prefixes.items[idx].tombstones.items, n) != null) return error.AlreadyTombstoned;

        var git_copy: ?[]const u8 = null;
        if (refs.git_commit) |c| {
            try validateGitCommit(c);
            git_copy = try self.allocator.dupe(u8, c);
        }

        try self.prefixes.items[idx].tombstones.append(self.allocator, .{
            .n = n,
            .git_commit = git_copy,
        });
        sortTombstones(self.prefixes.items[idx].tombstones.items);
    }

    pub fn registerNewPrefix(self: *Registry, obj_prefix: []const u8) !void {
        if (findPrefixIndex(self.prefixes.items, obj_prefix) != null) return error.DuplicateObjPrefix;
        const copy = try self.allocator.dupe(u8, obj_prefix);
        errdefer self.allocator.free(copy);
        try self.prefixes.append(self.allocator, .{ .obj_prefix = copy, .next = 1 });
    }

    pub fn renamePrefix(self: *Registry, old_prefix: []const u8, new_prefix: []const u8) !void {
        const idx = findPrefixIndex(self.prefixes.items, old_prefix) orelse return error.UnknownObjPrefix;
        if (std.mem.eql(u8, old_prefix, new_prefix)) return;
        if (findPrefixIndex(self.prefixes.items, new_prefix) != null) return error.DuplicateObjPrefix;

        const old_copy = self.prefixes.items[idx].obj_prefix;
        const new_copy = try self.allocator.dupe(u8, new_prefix);
        errdefer self.allocator.free(new_copy);

        self.prefixes.items[idx].obj_prefix = new_copy;
        self.allocator.free(old_copy);
    }

    /// Returns the next numeric suffix and advances `next`, skipping tombstoned values.
    pub fn allocateNextNumeric(self: *Registry, obj_prefix: []const u8) !u64 {
        const idx = findPrefixIndex(self.prefixes.items, obj_prefix) orelse return error.UnknownObjPrefix;
        var n = self.prefixes.items[idx].next;
        while (findTombstoneIndex(self.prefixes.items[idx].tombstones.items, n) != null) {
            n +%= 1;
        }
        self.prefixes.items[idx].next = n + 1;
        return n;
    }

    /// Collects registered prefix strings (borrowed from registry storage).
    pub fn objPrefixSlice(self: *const Registry, allocator: std.mem.Allocator) ![]const []const u8 {
        const out = try allocator.alloc([]const u8, self.prefixes.items.len);
        for (self.prefixes.items, 0..) |e, i| {
            out[i] = e.obj_prefix;
        }
        return out;
    }
};

/// Validates an object type prefix.
pub fn validateObjPrefix(obj_prefix: []const u8) error{InvalidObjPrefix}!void {
    if (obj_prefix.len == 0) return error.InvalidObjPrefix;
    const c0 = obj_prefix[0];
    if (!std.ascii.isAlphabetic(c0)) return error.InvalidObjPrefix;
    for (obj_prefix[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        return error.InvalidObjPrefix;
    }
}

/// Validates a git commit object name (40 lowercase hex digits).
pub fn validateGitCommit(commit: []const u8) error{InvalidGitCommit}!void {
    if (commit.len != git_commit_hex_len) return error.InvalidGitCommit;
    for (commit) |c| {
        if (!std.ascii.isHex(c)) return error.InvalidGitCommit;
    }
}

fn mergePrefix(reg: *Registry, obj_prefix: []const u8, next: u64, tombstones_json: []const TombstoneJsonV2) !void {
    const copy = try reg.allocator.dupe(u8, obj_prefix);
    errdefer reg.allocator.free(copy);

    const idx = findPrefixIndex(reg.prefixes.items, copy);
    const entry = if (idx) |i|
        &reg.prefixes.items[i]
    else blk: {
        try reg.prefixes.append(reg.allocator, .{ .obj_prefix = copy, .next = next });
        break :blk &reg.prefixes.items[reg.prefixes.items.len - 1];
    };

    if (idx != null) {
        entry.next = @max(entry.next, next);
        reg.allocator.free(copy);
    }

    for (tombstones_json) |tj| {
        if (tj.git_commit) |c| try validateGitCommit(c);
        const existing = findTombstoneIndex(entry.tombstones.items, tj.n);
        if (existing) |ti| {
            const cur = &entry.tombstones.items[ti];
            const incoming_better = tombstoneRicherThan(cur.*, tj);
            if (!incoming_better) continue;
            if (cur.git_commit) |old| reg.allocator.free(old);
            cur.git_commit = if (tj.git_commit) |nc| try reg.allocator.dupe(u8, nc) else null;
        } else {
            const gc = if (tj.git_commit) |nc| try reg.allocator.dupe(u8, nc) else null;
            try entry.tombstones.append(reg.allocator, .{ .n = tj.n, .git_commit = gc });
        }
    }
    sortTombstones(entry.tombstones.items);
}

fn tombstoneRicherThan(cur: TombstoneEntry, incoming: TombstoneJsonV2) bool {
    const cur_has = cur.git_commit != null;
    const inc_has = incoming.git_commit != null;
    if (inc_has and !cur_has) return true;
    if (inc_has and cur_has) {
        return std.mem.order(u8, incoming.git_commit.?, cur.git_commit.?) == .gt;
    }
    return false;
}

fn sortTombstones(items: []TombstoneEntry) void {
    std.mem.sortUnstable(TombstoneEntry, items, {}, struct {
        fn less(_: void, a: TombstoneEntry, b: TombstoneEntry) bool {
            return a.n < b.n;
        }
    }.less);
}

fn sortPrefixes(items: []Registry.PrefixEntry) void {
    std.mem.sortUnstable(Registry.PrefixEntry, items, {}, struct {
        fn less(_: void, a: Registry.PrefixEntry, b: Registry.PrefixEntry) bool {
            return std.mem.order(u8, a.obj_prefix, b.obj_prefix) == .lt;
        }
    }.less);
}

fn findTombstoneIndex(items: []const TombstoneEntry, n: u64) ?usize {
    for (items, 0..) |e, i| {
        if (e.n == n) return i;
    }
    return null;
}

fn joinRegistryPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ repo_root, fits_dir_name, registry_file_name });
}

fn openPath(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

fn readFileAlloc(file: Io.File, io: Io, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > max_bytes) return error.FileTooBig;
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    if (got != n) return error.UnexpectedEndOfFile;
    return buf;
}

fn findPrefixIndex(items: []const Registry.PrefixEntry, obj_prefix: []const u8) ?usize {
    for (items, 0..) |e, i| {
        if (std.mem.eql(u8, e.obj_prefix, obj_prefix)) return i;
    }
    return null;
}

test "allocate monotonic per prefix" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerNewPrefix("REQ");
    try reg.registerNewPrefix("BUG");

    try std.testing.expectEqual(@as(u64, 1), try reg.allocateNextNumeric("REQ"));
    try std.testing.expectEqual(@as(u64, 2), try reg.allocateNextNumeric("REQ"));
    try std.testing.expectEqual(@as(u64, 1), try reg.allocateNextNumeric("BUG"));
    try std.testing.expectEqual(@as(u64, 3), try reg.allocateNextNumeric("REQ"));
}

test "allocate skips tombstoned suffix" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerNewPrefix("REQ");
    _ = try reg.allocateNextNumeric("REQ");
    reg.prefixes.items[0].next = 2;
    try reg.tombstoneNumeric("REQ", 2, .{});
    try std.testing.expectEqual(@as(u64, 3), try reg.allocateNextNumeric("REQ"));
}

test "tombstone duplicate" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerNewPrefix("REQ");
    try reg.tombstoneNumeric("REQ", 1, .{});
    try std.testing.expectError(error.AlreadyTombstoned, reg.tombstoneNumeric("REQ", 1, .{}));
}

test "validateGitCommit" {
    try validateGitCommit("a1b2c3d4e5f6789012345678901234567890abcd");
    try std.testing.expectError(error.InvalidGitCommit, validateGitCommit("short"));
    try std.testing.expectError(error.InvalidGitCommit, validateGitCommit("g1b2c3d4e5f6789012345678901234567890abcd"));
}

test "allocate requires registered prefix" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try std.testing.expectError(error.UnknownObjPrefix, reg.allocateNextNumeric("REQ"));
}

test "validateObjPrefix" {
    try validateObjPrefix("REQ");
    try validateObjPrefix("R2");
    try validateObjPrefix("a_b");
    try std.testing.expectError(error.InvalidObjPrefix, validateObjPrefix(""));
    try std.testing.expectError(error.InvalidObjPrefix, validateObjPrefix("9A"));
    try std.testing.expectError(error.InvalidObjPrefix, validateObjPrefix("A-B"));
}

test "registerNewPrefix duplicate" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerNewPrefix("REQ");
    try std.testing.expectError(error.DuplicateObjPrefix, reg.registerNewPrefix("REQ"));
}

test "renamePrefix" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerNewPrefix("REQ");
    _ = try reg.allocateNextNumeric("REQ");
    try reg.renamePrefix("REQ", "FOO");
    try std.testing.expect(!reg.hasObjPrefix("REQ"));
    try std.testing.expect(reg.hasObjPrefix("FOO"));
    try std.testing.expectEqual(@as(?u64, 2), reg.nextForObjPrefix("FOO"));
}
