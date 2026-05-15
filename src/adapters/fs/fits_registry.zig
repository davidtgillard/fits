//! Machine-owned allocation state for FITS object IDs under `.fits/`.
//! Humans should not edit these files; the CLI owns create/update semantics and
//! enforces monotonic numeric suffixes per object prefix so deleted numbers are never reused.

const std = @import("std");

const Io = std.Io;
const Dir = Io.Dir;

/// Subdirectory under the repository root where FITS stores non-human metadata.
pub const fits_dir_name: []const u8 = ".fits";

/// Registry filename inside [`fits_dir_name`].
pub const registry_file_name: []const u8 = "registry.json";

/// Current on-disk registry schema version written by [`Registry.save`].
pub const registry_version: u32 = 2;

/// JSON envelope written by [`Registry.save`]. `kind` distinguishes FITS files from stray JSON.
const RegistryJsonV2 = struct {
    version: u32,
    kind: []const u8,
    prefixes: []PrefixJsonV2,
};

/// JSON prefix entry (v2).
const PrefixJsonV2 = struct {
    obj_prefix: []const u8,
    /// Next numeric suffix to assign for this prefix (natural numbers, starting at 1).
    next: u64,
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

/// In-memory registry: per-prefix monotonic counter. `next` is the next suffix to hand out.
pub const Registry = struct {
    /// Allocator for the registry's internal storage.
    allocator: std.mem.Allocator,
    /// List of object prefixes and their next numeric suffix.
    prefixes: std.ArrayList(PrefixEntry) = .empty,

    /// Single prefix entry.
    pub const PrefixEntry = struct {
        obj_prefix: []const u8,
        next: u64,
    };

    /// Frees duplicated prefix strings and prefix list storage.
    ///
    /// Parameters:
    /// - `self`: Registry whose `prefixes` were populated by this module (owned `obj_prefix` slices).
    ///
    /// Returns: nothing.
    pub fn deinit(self: *Registry) void {
        for (self.prefixes.items) |entry| {
            self.allocator.free(entry.obj_prefix);
        }
        self.prefixes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Loads registry from `repo_root`/.fits/registry.json`, or returns an empty registry if missing.
    ///
    /// Parameters:
    /// - `allocator`: Used for path buffers, parse output, and owned `obj_prefix` duplicates.
    /// - `io`: Process I/O implementation (used for all file operations).
    /// - `repo_root`: Repository root (relative or absolute path segment).
    ///
    /// Returns: a [`Registry`] on success. Caller must call [`deinit`].
    /// On failure: JSON parse errors, malformed `kind`/`version`, or I/O errors from read.
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
                    try mergePrefix(&reg, pj.slug, pj.next);
                }
            },
            2 => {
                var parsed_v2 = try std.json.parseFromSlice(RegistryJsonV2, allocator, contents, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed_v2.deinit();
                for (parsed_v2.value.prefixes) |pj| {
                    try mergePrefix(&reg, pj.obj_prefix, pj.next);
                }
            },
            else => return error.UnsupportedRegistryVersion,
        }

        sortPrefixes(reg.prefixes.items);
        return reg;
    }

    /// Writes registry to disk atomically (temp file + rename) under `repo_root`/.fits/.
    ///
    /// Parameters:
    /// - `self`: Registry state to persist (sorted by prefix for stable output).
    /// - `io`: Process I/O implementation (used for all file operations).
    /// - `repo_root`: Repository root used when joining `.fits/registry.json`.
    ///
    /// Returns: nothing on success.
    /// On failure: I/O errors from directory creation, write, or rename.
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
        for (self.prefixes.items, 0..) |e, i| {
            prefixes_json[i] = .{ .obj_prefix = e.obj_prefix, .next = e.next };
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

    /// Returns whether `obj_prefix` is registered.
    ///
    /// Parameters:
    /// - `self`: Loaded registry.
    /// - `obj_prefix`: Object type prefix (e.g. `REQ`).
    ///
    /// Returns: `true` if a row exists for `obj_prefix`.
    pub fn hasObjPrefix(self: *const Registry, obj_prefix: []const u8) bool {
        return findPrefixIndex(self.prefixes.items, obj_prefix) != null;
    }

    /// Returns the `next` counter for `obj_prefix`, or `null` if not registered.
    ///
    /// Parameters:
    /// - `self`: Loaded registry.
    /// - `obj_prefix`: Object type prefix.
    ///
    /// Returns: the next numeric suffix that would be assigned, or `null` if unknown.
    pub fn nextForObjPrefix(self: *const Registry, obj_prefix: []const u8) ?u64 {
        const idx = findPrefixIndex(self.prefixes.items, obj_prefix) orelse return null;
        return self.prefixes.items[idx].next;
    }

    /// Registers a new object type prefix with `next = 1`.
    ///
    /// Parameters:
    /// - `self`: Registry to mutate.
    /// - `obj_prefix`: Prefix such as `REQ` (must pass [`validateObjPrefix`] first).
    ///
    /// Returns: nothing on success.
    /// On failure: [`error.DuplicateObjPrefix`] if already registered, or [`error.OutOfMemory`].
    pub fn registerNewPrefix(self: *Registry, obj_prefix: []const u8) !void {
        if (findPrefixIndex(self.prefixes.items, obj_prefix) != null) return error.DuplicateObjPrefix;
        const copy = try self.allocator.dupe(u8, obj_prefix);
        errdefer self.allocator.free(copy);
        try self.prefixes.append(self.allocator, .{ .obj_prefix = copy, .next = 1 });
    }

    /// Renames an existing object type prefix row, preserving `next`.
    ///
    /// Parameters:
    /// - `self`: Registry to mutate.
    /// - `old_prefix`: Existing prefix name.
    /// - `new_prefix`: New prefix name (must pass [`validateObjPrefix`]).
    ///
    /// Returns: nothing on success.
    /// On failure: [`error.UnknownObjPrefix`], [`error.DuplicateObjPrefix`], or [`error.OutOfMemory`].
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

    /// Returns the next numeric suffix for `obj_prefix` and advances the counter.
    ///
    /// Parameters:
    /// - `self`: Registry to mutate.
    /// - `obj_prefix`: Prefix such as `REQ` (must be registered and pass [`validateObjPrefix`]).
    ///
    /// Returns: the numeric part for the new object (e.g. `3` for `REQ-3`). Caller formats `{obj_prefix}-{n}`.
    /// On failure: [`error.UnknownObjPrefix`] if not registered.
    pub fn allocateNextNumeric(self: *Registry, obj_prefix: []const u8) !u64 {
        const idx = findPrefixIndex(self.prefixes.items, obj_prefix) orelse return error.UnknownObjPrefix;
        const n = self.prefixes.items[idx].next;
        self.prefixes.items[idx].next +|= 1;
        return n;
    }
};

/// Validates an object type prefix: starts with ASCII letter, then letters, digits, or underscore.
///
/// Parameters:
/// - `obj_prefix`: Candidate prefix from argv (e.g. `REQ`).
///
/// Returns: nothing on success, or [`error.InvalidObjPrefix`] if the pattern does not match.
pub fn validateObjPrefix(obj_prefix: []const u8) error{InvalidObjPrefix}!void {
    if (obj_prefix.len == 0) return error.InvalidObjPrefix;
    const c0 = obj_prefix[0];
    if (!std.ascii.isAlphabetic(c0)) return error.InvalidObjPrefix;
    for (obj_prefix[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        return error.InvalidObjPrefix;
    }
}

fn mergePrefix(reg: *Registry, obj_prefix: []const u8, next: u64) !void {
    const copy = try reg.allocator.dupe(u8, obj_prefix);
    errdefer reg.allocator.free(copy);

    if (findPrefixIndex(reg.prefixes.items, copy)) |idx| {
        const cur = &reg.prefixes.items[idx];
        cur.next = @max(cur.next, next);
        reg.allocator.free(copy);
    } else {
        try reg.prefixes.append(reg.allocator, .{ .obj_prefix = copy, .next = next });
    }
}

fn sortPrefixes(items: []Registry.PrefixEntry) void {
    std.mem.sortUnstable(Registry.PrefixEntry, items, {}, struct {
        fn less(_: void, a: Registry.PrefixEntry, b: Registry.PrefixEntry) bool {
            return std.mem.order(u8, a.obj_prefix, b.obj_prefix) == .lt;
        }
    }.less);
}

/// Joins `repo_root/.fits/registry.json` using the host path separator.
///
/// Parameters:
/// - `allocator`: Used for the returned path buffer.
/// - `repo_root`: Repository root segment.
///
/// Returns: an owned path string. Caller must free with `allocator`.
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

// Functional tests (temp dirs, disk I/O) live in `src/test/fits_registry_functional.zig`.

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
