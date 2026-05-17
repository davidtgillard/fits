//! Machine-owned allocation state for node and link ids under `.fits/`.
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

/// A tombstoned numeric suffix for a concrete type id prefix (must never be reissued).
pub const TombstoneEntry = struct {
    n: u64,
    git_commit: ?[]const u8 = null,
};

/// JSON tombstone row on disk.
const TombstoneJson = struct {
    n: u64,
    git_commit: ?[]const u8 = null,
};

/// JSON link-type entry on disk.
const LinkTypeJson = struct {
    link_type: []const u8,
    in_type: []const u8,
    out_type: []const u8,
    next: u64,
    tombstones: []TombstoneJson = &.{},
};

/// JSON abstract node-type entry on disk.
const AbstractNodeTypeJson = struct {
    type: []const u8,
    abstract: bool = true,
};

/// JSON concrete node-type entry on disk (with abstract parent).
const ConcreteNodeTypeJson = struct {
    type: []const u8,
    extends: []const u8,
    id_prefix: ?[]const u8 = null,
    next: u64,
    tombstones: []TombstoneJson = &.{},
};

/// JSON standalone concrete node-type entry on disk (no `extends`).
const StandaloneConcreteNodeTypeJson = struct {
    type: []const u8,
    id_prefix: ?[]const u8 = null,
    next: u64,
    tombstones: []TombstoneJson = &.{},
};

/// Parsed node-type row before dispatching to abstract vs concrete merge.
const NodeTypeJson = struct {
    type: []const u8,
    abstract: bool = false,
    id_prefix: ?[]const u8 = null,
    extends: ?[]const u8 = null,
    next: ?u64 = null,
    tombstones: []TombstoneJson = &.{},
};

/// In-memory registry: node types (abstract/concrete) and link types.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    node_types: std.ArrayList(NodeTypeEntry) = .empty,
    link_types: std.ArrayList(LinkTypeEntry) = .empty,

    /// Registered node type (abstract or concrete).
    pub const NodeTypeEntry = struct {
        type: []const u8,
        abstract: bool,
        id_prefix: ?[]const u8 = null,
        extends: ?[]const u8 = null,
        next: u64 = 0,
        tombstones: std.ArrayList(TombstoneEntry) = .empty,
    };

    /// Registered link type with endpoint type names and allocation state.
    pub const LinkTypeEntry = struct {
        link_type: []const u8,
        in_type: []const u8,
        out_type: []const u8,
        next: u64,
        tombstones: std.ArrayList(TombstoneEntry) = .empty,
    };

    /// Frees duplicated strings and nested tombstone storage.
    pub fn deinit(self: *Registry) void {
        for (self.node_types.items) |*entry| {
            self.allocator.free(entry.type);
            if (entry.id_prefix) |p| self.allocator.free(p);
            if (entry.extends) |e| self.allocator.free(e);
            for (entry.tombstones.items) |ts| {
                if (ts.git_commit) |c| self.allocator.free(c);
            }
            entry.tombstones.deinit(self.allocator);
        }
        self.node_types.deinit(self.allocator);

        for (self.link_types.items) |*entry| {
            self.allocator.free(entry.link_type);
            self.allocator.free(entry.in_type);
            self.allocator.free(entry.out_type);
            for (entry.tombstones.items) |ts| {
                if (ts.git_commit) |c| self.allocator.free(c);
            }
            entry.tombstones.deinit(self.allocator);
        }
        self.link_types.deinit(self.allocator);
        self.* = undefined;
    }

    /// Loads registry from `repo_root`/.fits/registry.json`, or empty if missing.
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

        var parsed = try std.json.parseFromSlice(RegistryJsonIn, allocator, contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        if (parsed.value.version != registry_version) return error.UnsupportedRegistryVersion;

        var reg: Registry = .{ .allocator = allocator };
        errdefer reg.deinit();

        for (parsed.value.node_types) |nj| {
            try mergeNodeType(&reg, nj);
        }

        for (parsed.value.link_types) |lj| {
            try mergeLinkType(&reg, lj.link_type, lj.in_type, lj.out_type, lj.next, lj.tombstones);
        }

        for (reg.node_types.items) |*entry| {
            sortTombstones(entry.tombstones.items);
        }
        sortNodeTypes(reg.node_types.items);

        for (reg.link_types.items) |*entry| {
            sortTombstones(entry.tombstones.items);
        }
        sortLinkTypes(reg.link_types.items);

        try validateNodeTypeGraph(&reg);
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

        const json_text = try registryJsonSlice(self);
        defer self.allocator.free(json_text);

        {
            var out = try cwd.createFile(io, tmp_path, .{ .read = false, .truncate = true, .exclusive = false });
            defer out.close(io);
            try out.writeStreamingAll(io, json_text);
            try out.sync(io);
        }

        try cwd.rename(tmp_path, cwd, final_path, io);
    }

    pub fn toJsonText(self: *Registry) ![]const u8 {
        return registryJsonSlice(self);
    }

    pub fn hasNodeType(self: *const Registry, type_name: []const u8) bool {
        return findNodeTypeIndex(self.node_types.items, type_name) != null;
    }

    pub fn isAbstractType(self: *const Registry, type_name: []const u8) bool {
        const idx = findNodeTypeIndex(self.node_types.items, type_name) orelse return false;
        return self.node_types.items[idx].abstract;
    }

    pub fn hasIdPrefix(self: *const Registry, id_prefix: []const u8) bool {
        return findNodeTypeIndexByIdPrefix(self.node_types.items, id_prefix) != null;
    }

    /// Deprecated name kept for incremental refactors; use [`hasIdPrefix`].
    pub fn hasObjPrefix(self: *const Registry, id_prefix: []const u8) bool {
        return self.hasIdPrefix(id_prefix);
    }

    pub fn idPrefixForType(self: *const Registry, type_name: []const u8) ?[]const u8 {
        const idx = findNodeTypeIndex(self.node_types.items, type_name) orelse return null;
        const entry = &self.node_types.items[idx];
        if (entry.abstract) return null;
        return entry.id_prefix;
    }

    pub fn nextForIdPrefix(self: *const Registry, id_prefix: []const u8) ?u64 {
        const idx = findNodeTypeIndexByIdPrefix(self.node_types.items, id_prefix) orelse return null;
        return self.node_types.items[idx].next;
    }

    pub fn isTombstoned(self: *const Registry, id_prefix: []const u8, n: u64) bool {
        const idx = findNodeTypeIndexByIdPrefix(self.node_types.items, id_prefix) orelse return false;
        return findTombstoneIndex(self.node_types.items[idx].tombstones.items, n) != null;
    }

    pub fn tombstoneNumeric(self: *Registry, id_prefix: []const u8, n: u64, refs: TombstoneRefs) !void {
        const idx = findNodeTypeIndexByIdPrefix(self.node_types.items, id_prefix) orelse return error.UnknownIdPrefix;
        if (self.node_types.items[idx].abstract) return error.AbstractNotInstantiable;
        if (findTombstoneIndex(self.node_types.items[idx].tombstones.items, n) != null) return error.AlreadyTombstoned;

        var git_copy: ?[]const u8 = null;
        if (refs.git_commit) |c| {
            try validateGitCommit(c);
            git_copy = try self.allocator.dupe(u8, c);
        }

        try self.node_types.items[idx].tombstones.append(self.allocator, .{
            .n = n,
            .git_commit = git_copy,
        });
        sortTombstones(self.node_types.items[idx].tombstones.items);
    }

    pub fn registerAbstractType(self: *Registry, type_name: []const u8) !void {
        try ensureNameAvailable(self, type_name);
        const copy = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(copy);
        try self.node_types.append(self.allocator, .{
            .type = copy,
            .abstract = true,
        });
    }

    /// Registers a concrete node type, optionally extending an abstract parent.
    ///
    /// Parameters:
    /// - `type_name`: Registry type name.
    /// - `extends_type`: When non-null, must name an existing **abstract** type.
    /// - `id_prefix`: When null, defaults to `type_name`.
    pub fn registerConcreteType(
        self: *Registry,
        type_name: []const u8,
        extends_type: ?[]const u8,
        id_prefix: ?[]const u8,
    ) !void {
        if (extends_type) |parent_name| {
            const parent_idx = findNodeTypeIndex(self.node_types.items, parent_name) orelse return error.UnknownNodeType;
            if (!self.node_types.items[parent_idx].abstract) return error.ExtendsNotAbstract;
        }

        try ensureNameAvailable(self, type_name);

        const prefix = id_prefix orelse type_name;
        if (findNodeTypeIndex(self.node_types.items, prefix) != null) return error.DuplicateIdPrefix;
        if (findNodeTypeIndexByIdPrefix(self.node_types.items, prefix) != null) return error.DuplicateIdPrefix;
        if (findLinkTypeIndex(self.link_types.items, prefix) != null) return error.IdPrefixCollidesWithLinkType;

        const type_copy = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(type_copy);
        const prefix_copy = try self.allocator.dupe(u8, prefix);
        errdefer self.allocator.free(prefix_copy);

        var extends_copy: ?[]const u8 = null;
        if (extends_type) |parent_name| {
            extends_copy = try self.allocator.dupe(u8, parent_name);
        }

        try self.node_types.append(self.allocator, .{
            .type = type_copy,
            .abstract = false,
            .id_prefix = prefix_copy,
            .extends = extends_copy,
            .next = 1,
        });
    }

    pub fn registerNewLinkType(
        self: *Registry,
        link_type: []const u8,
        in_type: []const u8,
        out_type: []const u8,
    ) !void {
        if (!self.hasNodeType(in_type) or !self.hasNodeType(out_type)) return error.UnknownNodeType;
        if (findLinkTypeIndex(self.link_types.items, link_type) != null) return error.DuplicateLinkType;
        if (self.hasNodeType(link_type)) return error.LinkTypeCollidesWithNodeType;

        const lt_copy = try self.allocator.dupe(u8, link_type);
        errdefer self.allocator.free(lt_copy);
        const in_copy = try self.allocator.dupe(u8, in_type);
        errdefer self.allocator.free(in_copy);
        const out_copy = try self.allocator.dupe(u8, out_type);
        errdefer self.allocator.free(out_copy);

        try self.link_types.append(self.allocator, .{
            .link_type = lt_copy,
            .in_type = in_copy,
            .out_type = out_copy,
            .next = 1,
        });
    }

    pub fn renameLinkType(self: *Registry, old_link_type: []const u8, new_link_type: []const u8) !void {
        const idx = findLinkTypeIndex(self.link_types.items, old_link_type) orelse return error.UnknownLinkType;
        if (std.mem.eql(u8, old_link_type, new_link_type)) return;
        if (findLinkTypeIndex(self.link_types.items, new_link_type) != null) return error.DuplicateLinkType;
        if (self.hasNodeType(new_link_type)) return error.LinkTypeCollidesWithNodeType;

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

    pub fn linkTypeInType(self: *const Registry, link_type: []const u8) ?[]const u8 {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return null;
        return self.link_types.items[idx].in_type;
    }

    pub fn linkTypeOutType(self: *const Registry, link_type: []const u8) ?[]const u8 {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return null;
        return self.link_types.items[idx].out_type;
    }

    /// Deprecated; use [`linkTypeInType`].
    pub fn linkTypeInPrefix(self: *const Registry, link_type: []const u8) ?[]const u8 {
        return self.linkTypeInType(link_type);
    }

    /// Deprecated; use [`linkTypeOutType`].
    pub fn linkTypeOutPrefix(self: *const Registry, link_type: []const u8) ?[]const u8 {
        return self.linkTypeOutType(link_type);
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

    pub fn linkTypeSlice(self: *const Registry, allocator: std.mem.Allocator) ![]const []const u8 {
        const out = try allocator.alloc([]const u8, self.link_types.items.len);
        for (self.link_types.items, 0..) |e, i| {
            out[i] = e.link_type;
        }
        return out;
    }

    /// Renames a node type; when concrete and `id_prefix == old_type`, also renames id prefix and link endpoint types.
    pub fn renameNodeType(self: *Registry, old_type: []const u8, new_type: []const u8) !void {
        if (findLinkTypeIndex(self.link_types.items, new_type) != null) return error.TypeNameCollidesWithLinkType;
        const idx = findNodeTypeIndex(self.node_types.items, old_type) orelse return error.UnknownNodeType;
        if (std.mem.eql(u8, old_type, new_type)) return;
        if (findNodeTypeIndex(self.node_types.items, new_type) != null) return error.DuplicateNodeType;

        const entry = &self.node_types.items[idx];
        const old_type_copy = entry.type;
        const new_type_copy = try self.allocator.dupe(u8, new_type);
        errdefer self.allocator.free(new_type_copy);
        entry.type = new_type_copy;
        self.allocator.free(old_type_copy);

        if (!entry.abstract) {
            const prefix = entry.id_prefix.?;
            if (std.mem.eql(u8, prefix, old_type)) {
                const new_prefix_copy = try self.allocator.dupe(u8, new_type);
                self.allocator.free(prefix);
                entry.id_prefix = new_prefix_copy;
            }
        }

        try self.rewriteExtendsOnChildren(old_type, new_type);
        try self.rewriteTypeInLinkTypes(old_type, new_type);
    }

    pub fn rewriteTypeInLinkTypes(self: *Registry, old_type: []const u8, new_type: []const u8) !void {
        for (self.link_types.items) |*entry| {
            if (std.mem.eql(u8, entry.in_type, old_type)) {
                const nc = try self.allocator.dupe(u8, new_type);
                self.allocator.free(entry.in_type);
                entry.in_type = nc;
            }
            if (std.mem.eql(u8, entry.out_type, old_type)) {
                const nc = try self.allocator.dupe(u8, new_type);
                self.allocator.free(entry.out_type);
                entry.out_type = nc;
            }
        }
    }

    pub fn rewriteExtendsOnChildren(self: *Registry, old_abstract: []const u8, new_abstract: []const u8) !void {
        for (self.node_types.items) |*entry| {
            if (entry.abstract) continue;
            if (entry.extends) |ext| {
                if (std.mem.eql(u8, ext, old_abstract)) {
                    const nc = try self.allocator.dupe(u8, new_abstract);
                    self.allocator.free(ext);
                    entry.extends = nc;
                }
            }
        }
    }

    pub fn allocateNextNumeric(self: *Registry, id_prefix: []const u8) !u64 {
        if (findNodeTypeIndex(self.node_types.items, id_prefix)) |ti| {
            if (self.node_types.items[ti].abstract) return error.AbstractNotInstantiable;
        }
        const idx = findNodeTypeIndexByIdPrefix(self.node_types.items, id_prefix) orelse return error.UnknownIdPrefix;
        if (self.node_types.items[idx].abstract) return error.AbstractNotInstantiable;
        var n = self.node_types.items[idx].next;
        while (findTombstoneIndex(self.node_types.items[idx].tombstones.items, n) != null) {
            n +%= 1;
        }
        self.node_types.items[idx].next = n + 1;
        return n;
    }

    /// Collects concrete id prefix strings (borrowed from registry storage).
    pub fn idPrefixSlice(self: *const Registry, allocator: std.mem.Allocator) ![]const []const u8 {
        var count: usize = 0;
        for (self.node_types.items) |e| {
            if (!e.abstract) count += 1;
        }
        const out = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        for (self.node_types.items) |e| {
            if (!e.abstract) {
                out[i] = e.id_prefix.?;
                i += 1;
            }
        }
        return out;
    }

    /// Deprecated; use [`idPrefixSlice`].
    pub fn objPrefixSlice(self: *const Registry, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.idPrefixSlice(allocator);
    }

    pub fn hasLiveNodeInstance(self: *const Registry, id_prefix: []const u8) bool {
        const idx = findNodeTypeIndexByIdPrefix(self.node_types.items, id_prefix) orelse return false;
        const entry = self.node_types.items[idx];
        if (entry.abstract) return false;
        var n: u64 = 1;
        while (n < entry.next) : (n += 1) {
            if (!self.isTombstoned(id_prefix, n)) return true;
        }
        return false;
    }

    pub fn hasLiveLinkInstance(self: *const Registry, link_type: []const u8) bool {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return false;
        const entry = self.link_types.items[idx];
        var n: u64 = 1;
        while (n < entry.next) : (n += 1) {
            if (!self.isLinkTombstoned(link_type, n)) return true;
        }
        return false;
    }

    /// Collects link type names whose `in_type` or `out_type` equals `type_name`.
    pub fn linkTypesReferencingType(
        self: *const Registry,
        allocator: std.mem.Allocator,
        type_name: []const u8,
    ) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit(allocator);
        }
        for (self.link_types.items) |entry| {
            if (std.mem.eql(u8, entry.in_type, type_name) or std.mem.eql(u8, entry.out_type, type_name)) {
                const copy = try allocator.dupe(u8, entry.link_type);
                try out.append(allocator, copy);
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Deprecated; use [`linkTypesReferencingType`].
    pub fn linkTypesReferencingPrefix(
        self: *const Registry,
        allocator: std.mem.Allocator,
        type_name: []const u8,
    ) ![]const []const u8 {
        return self.linkTypesReferencingType(allocator, type_name);
    }

    /// Returns owned names of concrete types whose `extends` equals `abstract_type`.
    pub fn concreteChildrenOf(
        self: *const Registry,
        allocator: std.mem.Allocator,
        abstract_type: []const u8,
    ) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit(allocator);
        }
        for (self.node_types.items) |entry| {
            if (entry.abstract) continue;
            if (entry.extends) |ext| {
                if (std.mem.eql(u8, ext, abstract_type)) {
                    const copy = try allocator.dupe(u8, entry.type);
                    try out.append(allocator, copy);
                }
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn removeNodeType(self: *Registry, type_name: []const u8) !void {
        const idx = findNodeTypeIndex(self.node_types.items, type_name) orelse return error.UnknownNodeType;
        var entry = self.node_types.items[idx];
        self.allocator.free(entry.type);
        if (entry.id_prefix) |p| self.allocator.free(p);
        if (entry.extends) |e| self.allocator.free(e);
        for (entry.tombstones.items) |ts| {
            if (ts.git_commit) |c| self.allocator.free(c);
        }
        entry.tombstones.deinit(self.allocator);
        _ = self.node_types.swapRemove(idx);
    }

    /// Deprecated; use [`removeNodeType`].
    pub fn removePrefix(self: *Registry, type_name: []const u8) !void {
        return self.removeNodeType(type_name);
    }

    pub fn removeLinkType(self: *Registry, link_type: []const u8) !void {
        const idx = findLinkTypeIndex(self.link_types.items, link_type) orelse return error.UnknownLinkType;
        var entry = self.link_types.items[idx];
        self.allocator.free(entry.link_type);
        self.allocator.free(entry.in_type);
        self.allocator.free(entry.out_type);
        for (entry.tombstones.items) |ts| {
            if (ts.git_commit) |c| self.allocator.free(c);
        }
        entry.tombstones.deinit(self.allocator);
        _ = self.link_types.swapRemove(idx);
    }
};

pub fn findNodeTypeIndex(items: []const Registry.NodeTypeEntry, type_name: []const u8) ?usize {
    for (items, 0..) |e, i| {
        if (std.mem.eql(u8, e.type, type_name)) return i;
    }
    return null;
}

pub fn findNodeTypeIndexByIdPrefix(items: []const Registry.NodeTypeEntry, id_prefix: []const u8) ?usize {
    for (items, 0..) |e, i| {
        if (e.abstract) continue;
        if (e.id_prefix) |p| {
            if (std.mem.eql(u8, p, id_prefix)) return i;
        }
    }
    return null;
}

fn ensureNameAvailable(reg: *Registry, name: []const u8) !void {
    if (findNodeTypeIndex(reg.node_types.items, name) != null) return error.DuplicateNodeType;
    if (findLinkTypeIndex(reg.link_types.items, name) != null) return error.TypeNameCollidesWithLinkType;
}

fn validateNodeTypeGraph(reg: *const Registry) !void {
    for (reg.node_types.items) |entry| {
        if (entry.abstract) {
            if (entry.id_prefix != null or entry.extends != null or entry.next != 0) return error.RegistryInvalid;
        } else {
            if (entry.id_prefix == null) return error.RegistryInvalid;
            if (entry.extends) |parent| {
                const parent_idx = findNodeTypeIndex(reg.node_types.items, parent) orelse return error.RegistryInvalid;
                if (!reg.node_types.items[parent_idx].abstract) return error.RegistryInvalid;
            }
        }
    }
    for (reg.link_types.items) |lt| {
        if (!reg.hasNodeType(lt.in_type) or !reg.hasNodeType(lt.out_type)) return error.RegistryInvalid;
    }
}

/// JSON envelope read from disk.
const RegistryJsonIn = struct {
    description: []const u8,
    version: u32,
    kind: []const u8,
    node_types: []NodeTypeJson,
    link_types: []LinkTypeJson = &.{},
};

fn registryJsonSlice(self: *Registry) ![]const u8 {
    sortNodeTypes(self.node_types.items);
    sortLinkTypes(self.link_types.items);

    var node_parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (node_parts.items) |p| self.allocator.free(p);
        node_parts.deinit(self.allocator);
    }

    var tombstone_bufs: std.ArrayList([]TombstoneJson) = .empty;
    defer {
        for (tombstone_bufs.items) |buf| self.allocator.free(buf);
        tombstone_bufs.deinit(self.allocator);
    }

    for (self.node_types.items) |e| {
        const part = if (e.abstract) blk: {
            const row = AbstractNodeTypeJson{ .type = e.type };
            break :blk try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(row, .{})});
        } else concrete_blk: {
            const ts_json = try self.allocator.alloc(TombstoneJson, e.tombstones.items.len);
            try tombstone_bufs.append(self.allocator, ts_json);
            for (e.tombstones.items, 0..) |ts, j| {
                ts_json[j] = .{ .n = ts.n, .git_commit = ts.git_commit };
            }
            const part = if (e.extends) |ext| extends_blk: {
                const row = ConcreteNodeTypeJson{
                    .type = e.type,
                    .extends = ext,
                    .id_prefix = e.id_prefix,
                    .next = e.next,
                    .tombstones = ts_json,
                };
                break :extends_blk try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(row, .{})});
            } else standalone_blk: {
                const row = StandaloneConcreteNodeTypeJson{
                    .type = e.type,
                    .id_prefix = e.id_prefix,
                    .next = e.next,
                    .tombstones = ts_json,
                };
                break :standalone_blk try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(row, .{})});
            };
            break :concrete_blk part;
        };
        try node_parts.append(self.allocator, part);
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
            ts_json[j] = .{ .n = ts.n, .git_commit = ts.git_commit };
        }
        link_types_json[i] = .{
            .link_type = e.link_type,
            .in_type = e.in_type,
            .out_type = e.out_type,
            .next = e.next,
            .tombstones = ts_json,
        };
    }

    const nodes_joined = try std.mem.join(self.allocator, ",", node_parts.items);
    defer self.allocator.free(nodes_joined);

    const links_text = try std.fmt.allocPrint(self.allocator, "{f}", .{
        std.json.fmt(link_types_json, .{}),
    });
    defer self.allocator.free(links_text);

    return std.fmt.allocPrint(self.allocator,
        \\{{
        \\  "description": "{s}",
        \\  "version": {d},
        \\  "kind": "{s}",
        \\  "node_types": [{s}],
        \\  "link_types": {s}
        \\}}
    , .{
        registry_validate.registry_description,
        registry_version,
        registry_validate.registry_kind,
        nodes_joined,
        links_text,
    });
}

fn mergeNodeType(reg: *Registry, nj: NodeTypeJson) !void {
    if (nj.abstract) {
        try mergeAbstractNodeType(reg, nj.type);
        return;
    }
    const prefix = nj.id_prefix orelse nj.type;
    const next = nj.next orelse return error.RegistryInvalid;
    try mergeConcreteNodeType(reg, nj.type, prefix, nj.extends, next, nj.tombstones);
}

fn mergeAbstractNodeType(reg: *Registry, type_name: []const u8) !void {
    const copy = try reg.allocator.dupe(u8, type_name);
    errdefer reg.allocator.free(copy);

    const idx = findNodeTypeIndex(reg.node_types.items, copy);
    if (idx != null) {
        reg.allocator.free(copy);
        return;
    }
    try reg.node_types.append(reg.allocator, .{
        .type = copy,
        .abstract = true,
    });
}

fn mergeConcreteNodeType(
    reg: *Registry,
    type_name: []const u8,
    id_prefix: []const u8,
    extends: ?[]const u8,
    next: u64,
    tombstones_json: []const TombstoneJson,
) !void {
    const type_copy = try reg.allocator.dupe(u8, type_name);
    errdefer reg.allocator.free(type_copy);
    const prefix_copy = try reg.allocator.dupe(u8, id_prefix);
    errdefer reg.allocator.free(prefix_copy);

    var extends_copy: ?[]const u8 = null;
    if (extends) |parent_name| {
        extends_copy = try reg.allocator.dupe(u8, parent_name);
    }

    const idx = findNodeTypeIndex(reg.node_types.items, type_copy);
    const entry: *Registry.NodeTypeEntry = if (idx) |i| blk: {
        reg.allocator.free(type_copy);
        reg.allocator.free(prefix_copy);
        if (extends_copy) |ec| reg.allocator.free(ec);
        const e = &reg.node_types.items[i];
        e.next = @max(e.next, next);
        break :blk e;
    } else blk: {
        try reg.node_types.append(reg.allocator, .{
            .type = type_copy,
            .abstract = false,
            .id_prefix = prefix_copy,
            .extends = extends_copy,
            .next = next,
        });
        break :blk &reg.node_types.items[reg.node_types.items.len - 1];
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

/// Relative display path for `.fits/registry.json` under `repo_root`.
pub fn formatRegistryRelPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    if (std.mem.eql(u8, repo_root, ".")) {
        return std.fs.path.join(allocator, &.{ fits_dir_name, registry_file_name });
    }
    return std.fs.path.join(allocator, &.{ repo_root, fits_dir_name, registry_file_name });
}

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

pub fn printValidationReport(registry_path: []const u8, report: *const registry_validate.ValidationReport) void {
    report.print(registry_path);
}

/// Validates a type name or id prefix string.
pub fn validateTypeName(name: []const u8) error{InvalidTypeName}!void {
    if (name.len == 0) return error.InvalidTypeName;
    const c0 = name[0];
    if (!std.ascii.isAlphabetic(c0)) return error.InvalidTypeName;
    for (name[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        return error.InvalidTypeName;
    }
}

/// Deprecated; use [`validateTypeName`].
pub fn validateObjPrefix(name: []const u8) error{InvalidObjPrefix}!void {
    validateTypeName(name) catch return error.InvalidObjPrefix;
}

pub fn validateGitCommit(commit: []const u8) error{InvalidGitCommit}!void {
    if (commit.len != git_commit_hex_len) return error.InvalidGitCommit;
    for (commit) |c| {
        if (!std.ascii.isHex(c)) return error.InvalidGitCommit;
    }
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

fn sortNodeTypes(items: []Registry.NodeTypeEntry) void {
    std.mem.sortUnstable(Registry.NodeTypeEntry, items, {}, struct {
        fn less(_: void, a: Registry.NodeTypeEntry, b: Registry.NodeTypeEntry) bool {
            return std.mem.order(u8, a.type, b.type) == .lt;
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
    in_type: []const u8,
    out_type: []const u8,
    next: u64,
    tombstones_json: []const TombstoneJson,
) !void {
    const lt_copy = try reg.allocator.dupe(u8, link_type);
    errdefer reg.allocator.free(lt_copy);

    const idx = findLinkTypeIndex(reg.link_types.items, lt_copy);
    const entry: *Registry.LinkTypeEntry = if (idx) |i| blk: {
        reg.allocator.free(lt_copy);
        const e = &reg.link_types.items[i];
        if (!std.mem.eql(u8, e.in_type, in_type) or !std.mem.eql(u8, e.out_type, out_type)) {
            return error.RegistryLinkTypeMergeConflict;
        }
        e.next = @max(e.next, next);
        break :blk e;
    } else blk: {
        const in_copy = try reg.allocator.dupe(u8, in_type);
        errdefer reg.allocator.free(in_copy);
        const out_copy = try reg.allocator.dupe(u8, out_type);
        errdefer reg.allocator.free(out_copy);
        try reg.link_types.append(reg.allocator, .{
            .link_type = lt_copy,
            .in_type = in_copy,
            .out_type = out_copy,
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

test "allocate monotonic per id prefix" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerAbstractType("req");
    try reg.registerConcreteType("REQ", "req", null);
    try reg.registerConcreteType("BUG", "req", null);

    try std.testing.expectEqual(@as(u64, 1), try reg.allocateNextNumeric("REQ"));
    try std.testing.expectEqual(@as(u64, 2), try reg.allocateNextNumeric("REQ"));
    try std.testing.expectEqual(@as(u64, 1), try reg.allocateNextNumeric("BUG"));
}

test "abstract not instantiable" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerAbstractType("req");
    try reg.registerConcreteType("REQ", "req", null);
    try std.testing.expectError(error.AbstractNotInstantiable, reg.allocateNextNumeric("req"));
}

test "registerConcreteType requires abstract parent" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try std.testing.expectError(error.UnknownNodeType, reg.registerConcreteType("REQ", "req", null));
    try reg.registerAbstractType("req");
    try reg.registerConcreteType("REQ", "req", null);
    try std.testing.expectError(error.ExtendsNotAbstract, reg.registerConcreteType("BUG", "REQ", null));
}

test "renameNodeType abstract updates children and links" {
    const alloc = std.testing.allocator;
    var reg: Registry = .{ .allocator = alloc };
    defer reg.deinit();

    try reg.registerAbstractType("req");
    try reg.registerConcreteType("REQ", "req", null);
    try reg.registerAbstractType("doc");
    try reg.registerConcreteType("DOC", "doc", null);
    try reg.registerNewLinkType("implements", "req", "doc");

    try reg.renameNodeType("req", "requirement");
    try std.testing.expect(reg.hasNodeType("requirement"));
    try std.testing.expectEqualStrings("requirement", reg.node_types.items[1].extends.?);
    try std.testing.expectEqualStrings("requirement", reg.linkTypeInType("implements").?);
}
