//! Machine-owned allocation state for object ids under `.fits/`.
//! Humans should not edit these files; the CLI owns create/update semantics,
//! tombstones deleted numeric suffixes (with optional VCS refs), and monotonic `next` counters.

const std = @import("std");

const registry_validate = @import("registry_validate.zig");

const Io = std.Io;
const Dir = Io.Dir;

/// Subdirectory under the repository root where `fits` stores non-human metadata.
pub const fits_dir_name: []const u8 = ".fits";

/// Registry filename inside [`fits_dir_name`].
pub const registry_file_name: []const u8 = "registry.json";

/// Current on-disk registry schema version written by [`Registry.save`].
pub const registry_version: u32 = 1;

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

/// JSON tombstone row on disk.
const TombstoneJson = struct {
    n: u64,
    git_commit: ?[]const u8 = null,
};

/// JSON envelope written by [`Registry.save`].
const RegistryJson = struct {
    description: []const u8,
    version: u32,
    kind: []const u8,
    prefixes: []PrefixJson,
    link_types: []LinkTypeJson = &.{},
};

/// JSON link-type entry on disk.
const LinkTypeJson = struct {
    link_type: []const u8,
    in_obj_prefix: []const u8,
    out_obj_prefix: []const u8,
    next: u64,
    tombstones: []TombstoneJson = &.{},
};

/// JSON prefix entry on disk.
const PrefixJson = struct {
    obj_prefix: []const u8,
    next: u64,
    tombstones: []TombstoneJson = &.{},
};

/// In-memory registry: per-prefix monotonic counter and tombstone list.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    prefixes: std.ArrayList(PrefixEntry) = .empty,
    link_types: std.ArrayList(LinkTypeEntry) = .empty,

    /// Registered link type with endpoint object prefixes and allocation state.
    pub const LinkTypeEntry = struct {
        link_type: []const u8,
        in_obj_prefix: []const u8,
        out_obj_prefix: []const u8,
        next: u64,
        tombstones: std.ArrayList(TombstoneEntry) = .empty,
    };

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

        for (self.link_types.items) |*entry| {
            self.allocator.free(entry.link_type);
            self.allocator.free(entry.in_obj_prefix);
            self.allocator.free(entry.out_obj_prefix);
            for (entry.tombstones.items) |ts| {
                if (ts.git_commit) |c| self.allocator.free(c);
            }
            entry.tombstones.deinit(self.allocator);
        }
        self.link_types.deinit(self.allocator);
        self.* = undefined;
    }

    /// Loads registry from `repo_root`/.fits/registry.json`, or empty if missing.
    ///
    /// Parameters:
    /// - `validation_out`: When non-null and validation fails, receives an owned [`registry_validate.ValidationReport`]
    ///   the caller must [`registry_validate.ValidationReport.deinit`].
    ///
    /// Returns: an in-memory registry on success.
    /// On failure: I/O errors, JSON parse errors, or [`error.RegistryInvalid`] when structural validation fails.
    pub fn load(
        allocator: std.mem.Allocator,
        io: Io,
        repo_root: []const u8,
        validation_out: ?*registry_validate.ValidationReport,
    ) !Registry {
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

        var validation_report = try registry_validate.validateRegistryDocument(allocator, contents);
        if (!validation_report.isEmpty()) {
            if (validation_out) |out| {
                out.* = validation_report;
            } else {
                validation_report.deinit();
            }
            return error.RegistryInvalid;
        }
        validation_report.deinit();

        var parsed = try std.json.parseFromSlice(RegistryJson, allocator, contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        if (parsed.value.version != registry_version) return error.UnsupportedRegistryVersion;

        var reg: Registry = .{ .allocator = allocator };
        errdefer reg.deinit();

        for (parsed.value.prefixes) |pj| {
            try mergePrefix(&reg, pj.obj_prefix, pj.next, pj.tombstones);
        }

        for (parsed.value.link_types) |lj| {
            try mergeLinkType(&reg, lj.link_type, lj.in_obj_prefix, lj.out_obj_prefix, lj.next, lj.tombstones);
        }

        for (reg.prefixes.items) |*entry| {
            sortTombstones(entry.tombstones.items);
        }
        sortPrefixes(reg.prefixes.items);

        for (reg.link_types.items) |*entry| {
            sortTombstones(entry.tombstones.items);
        }
        sortLinkTypes(reg.link_types.items);
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
        sortLinkTypes(self.link_types.items);

        var prefixes_json = try self.allocator.alloc(PrefixJson, self.prefixes.items.len);
        defer self.allocator.free(prefixes_json);

        var tombstone_bufs: std.ArrayList([]TombstoneJson) = .empty;
        defer {
            for (tombstone_bufs.items) |buf| self.allocator.free(buf);
            tombstone_bufs.deinit(self.allocator);
        }

        for (self.prefixes.items, 0..) |e, i| {
            const ts_json = try self.allocator.alloc(TombstoneJson, e.tombstones.items.len);
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

        var link_tombstone_bufs: std.ArrayList([]TombstoneJson) = .empty;
        defer {
            for (link_tombstone_bufs.items) |buf| self.allocator.free(buf);
            link_tombstone_bufs.deinit(self.allocator);
        }

        var link_types_json = try self.allocator.alloc(LinkTypeJson, self.link_types.items.len);
        defer self.allocator.free(link_types_json);

        for (self.link_types.items, 0..) |e, i| {
            const ts_json = try self.allocator.alloc(TombstoneJson, e.tombstones.items.len);
            try link_tombstone_bufs.append(self.allocator, ts_json);
            for (e.tombstones.items, 0..) |ts, j| {
                ts_json[j] = .{
                    .n = ts.n,
                    .git_commit = ts.git_commit,
                };
            }
            link_types_json[i] = .{
                .link_type = e.link_type,
                .in_obj_prefix = e.in_obj_prefix,
                .out_obj_prefix = e.out_obj_prefix,
                .next = e.next,
                .tombstones = ts_json,
            };
        }

        const envelope = RegistryJson{
            .description = registry_validate.registry_description,
            .version = registry_version,
            .kind = "fits-registry-v1",
            .prefixes = prefixes_json,
            .link_types = link_types_json,
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
        if (findLinkTypeIndex(self.link_types.items, obj_prefix) != null) return error.ObjPrefixCollidesWithLinkType;
        if (findPrefixIndex(self.prefixes.items, obj_prefix) != null) return error.DuplicateObjPrefix;
        const copy = try self.allocator.dupe(u8, obj_prefix);
        errdefer self.allocator.free(copy);
        try self.prefixes.append(self.allocator, .{ .obj_prefix = copy, .next = 1 });
    }

    /// Registers a new link type from `out_obj_prefix` objects to `in_obj_prefix` objects.
    ///
    /// Parameters:
    /// - `link_type`: Name for this link type (must not match any object type prefix).
    /// - `in_obj_prefix`: Objects that receive incoming links (`IN`).
    /// - `out_obj_prefix`: Objects that emit outgoing links (`OUT`).
    pub fn registerNewLinkType(
        self: *Registry,
        link_type: []const u8,
        in_obj_prefix: []const u8,
        out_obj_prefix: []const u8,
    ) !void {
        if (!self.hasObjPrefix(in_obj_prefix) or !self.hasObjPrefix(out_obj_prefix)) return error.UnknownObjPrefix;
        if (findLinkTypeIndex(self.link_types.items, link_type) != null) return error.DuplicateLinkType;
        if (self.hasObjPrefix(link_type)) return error.LinkTypeCollidesWithObjPrefix;

        const lt_copy = try self.allocator.dupe(u8, link_type);
        errdefer self.allocator.free(lt_copy);
        const in_copy = try self.allocator.dupe(u8, in_obj_prefix);
        errdefer self.allocator.free(in_copy);
        const out_copy = try self.allocator.dupe(u8, out_obj_prefix);
        errdefer self.allocator.free(out_copy);

        try self.link_types.append(self.allocator, .{
            .link_type = lt_copy,
            .in_obj_prefix = in_copy,
            .out_obj_prefix = out_copy,
            .next = 1,
        });
    }

    pub fn renameLinkType(self: *Registry, old_link_type: []const u8, new_link_type: []const u8) !void {
        const idx = findLinkTypeIndex(self.link_types.items, old_link_type) orelse return error.UnknownLinkType;
        if (std.mem.eql(u8, old_link_type, new_link_type)) return;
        if (findLinkTypeIndex(self.link_types.items, new_link_type) != null) return error.DuplicateLinkType;
        if (self.hasObjPrefix(new_link_type)) return error.LinkTypeCollidesWithObjPrefix;

        const old_copy = self.link_types.items[idx].link_type;
        const new_copy = try self.allocator.dupe(u8, new_link_type);
        errdefer self.allocator.free(new_copy);

        self.link_types.items[idx].link_type = new_copy;
        self.allocator.free(old_copy);
    }

    pub fn hasLinkType(self: *const Registry, link_type: []const u8) bool {
        return findLinkTypeIndex(self.link_types.items, link_type) != null;
    }

    pub fn nextForLinkType(self: *const Registry, link_type: []const u8) ?u64 {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return null;
        return self.link_types.items[idx].next;
    }

    pub fn linkTypeInPrefix(self: *const Registry, link_type: []const u8) ?[]const u8 {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return null;
        return self.link_types.items[idx].in_obj_prefix;
    }

    pub fn linkTypeOutPrefix(self: *const Registry, link_type: []const u8) ?[]const u8 {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return null;
        return self.link_types.items[idx].out_obj_prefix;
    }

    pub fn isLinkTombstoned(self: *const Registry, link_type: []const u8, n: u64) bool {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return false;
        return findTombstoneIndex(self.link_types.items[idx].tombstones.items, n) != null;
    }

    pub fn tombstoneLinkNumeric(self: *Registry, link_type: []const u8, n: u64, refs: TombstoneRefs) !void {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return error.UnknownLinkType;
        if (findTombstoneIndex(self.link_types.items[idx].tombstones.items, n) != null) return error.AlreadyTombstoned;

        var git_copy: ?[]const u8 = null;
        if (refs.git_commit) |c| {
            try validateGitCommit(c);
            git_copy = try self.allocator.dupe(u8, c);
        }

        try self.link_types.items[idx].tombstones.append(self.allocator, .{
            .n = n,
            .git_commit = git_copy,
        });
        sortTombstones(self.link_types.items[idx].tombstones.items);
    }

    pub fn allocateNextLinkNumeric(self: *Registry, link_type: []const u8) !u64 {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return error.UnknownLinkType;
        var n = self.link_types.items[idx].next;
        while (findTombstoneIndex(self.link_types.items[idx].tombstones.items, n) != null) {
            n +%= 1;
        }
        self.link_types.items[idx].next = n + 1;
        return n;
    }

    /// Collects registered link type strings (borrowed from registry storage).
    pub fn linkTypeSlice(self: *const Registry, allocator: std.mem.Allocator) ![]const []const u8 {
        const out = try allocator.alloc([]const u8, self.link_types.items.len);
        for (self.link_types.items, 0..) |e, i| {
            out[i] = e.link_type;
        }
        return out;
    }

    pub fn renamePrefix(self: *Registry, old_prefix: []const u8, new_prefix: []const u8) !void {
        if (findLinkTypeIndex(self.link_types.items, new_prefix) != null) return error.ObjPrefixCollidesWithLinkType;
        const idx = findPrefixIndex(self.prefixes.items, old_prefix) orelse return error.UnknownObjPrefix;
        if (std.mem.eql(u8, old_prefix, new_prefix)) return;
        if (findPrefixIndex(self.prefixes.items, new_prefix) != null) return error.DuplicateObjPrefix;

        const old_copy = self.prefixes.items[idx].obj_prefix;
        const new_copy = try self.allocator.dupe(u8, new_prefix);
        errdefer self.allocator.free(new_copy);

        self.prefixes.items[idx].obj_prefix = new_copy;
        self.allocator.free(old_copy);
        try self.rewriteObjPrefixInLinkTypes(old_prefix, new_prefix);
    }

    /// Updates `in_obj_prefix` and `out_obj_prefix` on link types when an object type is renamed.
    pub fn rewriteObjPrefixInLinkTypes(self: *Registry, old_prefix: []const u8, new_prefix: []const u8) !void {
        for (self.link_types.items) |*entry| {
            if (std.mem.eql(u8, entry.in_obj_prefix, old_prefix)) {
                const nc = try self.allocator.dupe(u8, new_prefix);
                self.allocator.free(entry.in_obj_prefix);
                entry.in_obj_prefix = nc;
            }
            if (std.mem.eql(u8, entry.out_obj_prefix, old_prefix)) {
                const nc = try self.allocator.dupe(u8, new_prefix);
                self.allocator.free(entry.out_obj_prefix);
                entry.out_obj_prefix = nc;
            }
        }
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

/// Relative display path for `.fits/registry.json` under `repo_root`.
pub fn formatRegistryRelPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    if (std.mem.eql(u8, repo_root, ".")) {
        return std.fs.path.join(allocator, &.{ fits_dir_name, registry_file_name });
    }
    return std.fs.path.join(allocator, &.{ repo_root, fits_dir_name, registry_file_name });
}

/// Loads the registry and prints all validation issues to stderr on [`error.RegistryInvalid`].
///
/// Parameters:
/// - `allocator`: Used for paths and registry buffers.
/// - `io`: Process I/O (unused today; reserved for future stderr routing).
/// - `repo_root`: Repository root containing `.fits/`.
///
/// Returns: an in-memory registry on success.
/// On failure: same errors as [`Registry.load`], with validation issues printed when applicable.
pub fn loadRegistry(allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !Registry {
    var validation_report: registry_validate.ValidationReport = undefined;
    const reg = Registry.load(allocator, io, repo_root, &validation_report) catch |err| {
        if (err == error.RegistryInvalid) {
            const display_path = formatRegistryRelPath(allocator, repo_root) catch {
                validation_report.deinit();
                return err;
            };
            defer allocator.free(display_path);
            validation_report.print(display_path);
            validation_report.deinit();
        }
        return err;
    };
    return reg;
}

/// Prints a validation report using the standard registry error line format.
pub fn printValidationReport(registry_path: []const u8, report: *const registry_validate.ValidationReport) void {
    report.print(registry_path);
}

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

fn mergePrefix(reg: *Registry, obj_prefix: []const u8, next: u64, tombstones_json: []const TombstoneJson) !void {
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

fn tombstoneRicherThan(cur: TombstoneEntry, incoming: TombstoneJson) bool {
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

fn sortLinkTypes(items: []Registry.LinkTypeEntry) void {
    std.mem.sortUnstable(Registry.LinkTypeEntry, items, {}, struct {
        fn less(_: void, a: Registry.LinkTypeEntry, b: Registry.LinkTypeEntry) bool {
            return std.mem.order(u8, a.link_type, b.link_type) == .lt;
        }
    }.less);
}

fn mergeLinkType(
    reg: *Registry,
    link_type: []const u8,
    in_obj_prefix: []const u8,
    out_obj_prefix: []const u8,
    next: u64,
    tombstones_json: []const TombstoneJson,
) !void {
    const lt_copy = try reg.allocator.dupe(u8, link_type);
    errdefer reg.allocator.free(lt_copy);

    const idx = findLinkTypeIndex(reg.link_types.items, lt_copy);
    const entry: *Registry.LinkTypeEntry = if (idx) |i| blk: {
        reg.allocator.free(lt_copy);
        const e = &reg.link_types.items[i];
        if (!std.mem.eql(u8, e.in_obj_prefix, in_obj_prefix) or !std.mem.eql(u8, e.out_obj_prefix, out_obj_prefix)) {
            return error.RegistryLinkTypeMergeConflict;
        }
        e.next = @max(e.next, next);
        break :blk e;
    } else blk: {
        const in_copy = try reg.allocator.dupe(u8, in_obj_prefix);
        errdefer reg.allocator.free(in_copy);
        const out_copy = try reg.allocator.dupe(u8, out_obj_prefix);
        errdefer reg.allocator.free(out_copy);
        try reg.link_types.append(reg.allocator, .{
            .link_type = lt_copy,
            .in_obj_prefix = in_copy,
            .out_obj_prefix = out_copy,
            .next = next,
        });
        break :blk &reg.link_types.items[reg.link_types.items.len - 1];
    };

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

fn findLinkTypeIndex(items: []const Registry.LinkTypeEntry, link_type: []const u8) ?usize {
    for (items, 0..) |e, i| {
        if (std.mem.eql(u8, e.link_type, link_type)) return i;
    }
    return null;
}

fn findTombstoneIndex(items: []const TombstoneEntry, n: u64) ?usize {
    for (items, 0..) |e, i| {
        if (e.n == n) return i;
    }
    return null;
}

/// Joins `repo_root` with `.fits/registry.json`.
pub fn joinRegistryPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
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
