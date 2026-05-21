//! Compare live `.fits/registry.json` type schema to a persona `registry.snapshot.json`.

const std = @import("std");
const fits_registry = @import("fits_registry.zig");
const registry_validate = @import("registry_validate.zig");

const Io = std.Io;

const SnapshotJson = struct {
    node_types: []NodeTypeJson = &.{},
    link_types: []LinkTypeJson = &.{},
};

const NodeTypeJson = struct {
    type: []const u8,
    abstract: bool = false,
    id_prefix: ?[]const u8 = null,
    extends: ?[]const u8 = null,
};

const LinkTypeJson = struct {
    link_type: []const u8,
    in_type: []const u8,
    out_type: []const u8,
};

/// Type-only schema extracted from a registry document.
pub const TypeSchema = struct {
    node_types: []NodeTypeEntry,
    link_types: []LinkTypeEntry,

    pub const NodeTypeEntry = struct {
        type: []const u8,
        abstract: bool,
        id_prefix: ?[]const u8,
        extends: ?[]const u8,
    };

    pub const LinkTypeEntry = struct {
        link_type: []const u8,
        in_type: []const u8,
        out_type: []const u8,
    };

    pub fn deinit(self: *TypeSchema, allocator: std.mem.Allocator) void {
        for (self.node_types) |*nt| {
            allocator.free(nt.type);
            if (nt.id_prefix) |p| allocator.free(p);
            if (nt.extends) |e| allocator.free(e);
        }
        allocator.free(self.node_types);
        for (self.link_types) |*lt| {
            allocator.free(lt.link_type);
            allocator.free(lt.in_type);
            allocator.free(lt.out_type);
        }
        allocator.free(self.link_types);
        self.* = undefined;
    }
};

pub fn loadTypeSchema(
    allocator: std.mem.Allocator,
    io: Io,
    package_root: []const u8,
    snapshot_rel: []const u8,
) !TypeSchema {
    const path = try std.fs.path.join(allocator, &.{ package_root, snapshot_rel });
    defer allocator.free(path);
    return loadTypeSchemaFromPath(allocator, io, path);
}

fn nodeTypeMatches(live: fits_registry.Registry.NodeTypeEntry, snap: TypeSchema.NodeTypeEntry) bool {
    if (!std.mem.eql(u8, live.type, snap.type)) return false;
    if (live.abstract != snap.abstract) return false;
    if (live.abstract) return true;
    const live_prefix = live.id_prefix orelse return false;
    const snap_prefix = snap.id_prefix orelse live_prefix;
    if (!std.mem.eql(u8, live_prefix, snap_prefix)) return false;
    const live_ext = live.extends orelse return false;
    const snap_ext = snap.extends orelse live_ext;
    return std.mem.eql(u8, live_ext, snap_ext);
}

pub fn verifyRegistryMatchesSchema(reg: *const fits_registry.Registry, schema: *const TypeSchema) !void {
    if (reg.node_types.items.len != schema.node_types.len) return error.RegistrySnapshotMismatch;

    for (schema.node_types) |sn| {
        var found = false;
        for (reg.node_types.items) |live| {
            if (nodeTypeMatches(live, sn)) {
                found = true;
                break;
            }
        }
        if (!found) return error.RegistrySnapshotMismatch;
    }

    for (reg.node_types.items) |live| {
        var found = false;
        for (schema.node_types) |sn| {
            if (nodeTypeMatches(live, sn)) {
                found = true;
                break;
            }
        }
        if (!found) return error.RegistrySnapshotMismatch;
    }

    if (reg.link_types.items.len != schema.link_types.len) return error.RegistrySnapshotMismatch;
    for (schema.link_types) |sl| {
        const in_t = reg.linkTypeInType(sl.link_type) orelse return error.RegistrySnapshotMismatch;
        const out_t = reg.linkTypeOutType(sl.link_type) orelse return error.RegistrySnapshotMismatch;
        if (!std.mem.eql(u8, in_t, sl.in_type)) return error.RegistrySnapshotMismatch;
        if (!std.mem.eql(u8, out_t, sl.out_type)) return error.RegistrySnapshotMismatch;
    }
    for (reg.link_types.items) |live| {
        var found = false;
        for (schema.link_types) |sl| {
            if (std.mem.eql(u8, live.link_type, sl.link_type)) {
                found = true;
                break;
            }
        }
        if (!found) return error.RegistrySnapshotMismatch;
    }
}

pub fn verifyRegistryForPersona(
    allocator: std.mem.Allocator,
    io: Io,
    package_root: []const u8,
    snapshot_rel: []const u8,
    reg: *const fits_registry.Registry,
) !void {
    var schema = try loadTypeSchema(allocator, io, package_root, snapshot_rel);
    defer schema.deinit(allocator);
    try verifyRegistryMatchesSchema(reg, &schema);
}

/// Compares `reg` to the type schema at `snapshot_path` (absolute or cwd-relative file).
pub fn verifyRegistryAtSnapshot(
    allocator: std.mem.Allocator,
    io: Io,
    snapshot_path: []const u8,
    reg: *const fits_registry.Registry,
) !void {
    var schema = try loadTypeSchemaFromPath(allocator, io, snapshot_path);
    defer schema.deinit(allocator);
    try verifyRegistryMatchesSchema(reg, &schema);
}

/// Loads type schema from a snapshot file path (not package root + relative).
pub fn loadTypeSchemaFromPath(
    allocator: std.mem.Allocator,
    io: Io,
    snapshot_path: []const u8,
) !TypeSchema {
    var file = openFile(io, snapshot_path) catch |err| switch (err) {
        error.FileNotFound => return error.PersonaSnapshotNotFound,
        else => |e| return e,
    };
    defer file.close(io);

    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > 16 * 1024 * 1024) return error.FileTooBig;
    const contents = try allocator.alloc(u8, n);
    defer allocator.free(contents);
    const got = try file.readPositionalAll(io, contents, 0);
    if (got != n) return error.UnexpectedEndOfFile;

    var validation_report = try registry_validate.validateRegistryDocument(allocator, contents);
    defer validation_report.deinit();
    if (!validation_report.isEmpty()) return error.PersonaSnapshotInvalid;

    var parsed = try std.json.parseFromSlice(SnapshotJson, allocator, contents, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return try typeSchemaFromParsed(allocator, parsed.value);
}

fn typeSchemaFromParsed(allocator: std.mem.Allocator, root: SnapshotJson) !TypeSchema {
    var node_types: std.ArrayListUnmanaged(TypeSchema.NodeTypeEntry) = .empty;
    errdefer {
        for (node_types.items) |*nt| {
            allocator.free(nt.type);
            if (nt.id_prefix) |p| allocator.free(p);
            if (nt.extends) |e| allocator.free(e);
        }
        node_types.deinit(allocator);
    }
    for (root.node_types) |jn| {
        try node_types.append(allocator, .{
            .type = try allocator.dupe(u8, jn.type),
            .abstract = jn.abstract,
            .id_prefix = if (jn.id_prefix) |p| try allocator.dupe(u8, p) else null,
            .extends = if (jn.extends) |e| try allocator.dupe(u8, e) else null,
        });
    }
    var links: std.ArrayListUnmanaged(TypeSchema.LinkTypeEntry) = .empty;
    errdefer {
        for (links.items) |*lt| {
            allocator.free(lt.link_type);
            allocator.free(lt.in_type);
            allocator.free(lt.out_type);
        }
        links.deinit(allocator);
    }
    for (root.link_types) |jl| {
        try links.append(allocator, .{
            .link_type = try allocator.dupe(u8, jl.link_type),
            .in_type = try allocator.dupe(u8, jl.in_type),
            .out_type = try allocator.dupe(u8, jl.out_type),
        });
    }
    return .{
        .node_types = try node_types.toOwnedSlice(allocator),
        .link_types = try links.toOwnedSlice(allocator),
    };
}

/// Returns true when `id_prefix` appears in the snapshot file.
pub fn snapshotHasIdPrefix(
    allocator: std.mem.Allocator,
    io: Io,
    snapshot_path: []const u8,
    id_prefix: []const u8,
) !bool {
    var schema = try loadTypeSchemaFromPath(allocator, io, snapshot_path);
    defer schema.deinit(allocator);
    return schemaHasIdPrefix(&schema, id_prefix);
}

/// Returns true when `id_prefix` is a concrete type id prefix declared in the snapshot.
pub fn schemaHasIdPrefix(schema: *const TypeSchema, id_prefix: []const u8) bool {
    for (schema.node_types) |nt| {
        if (nt.abstract) continue;
        if (nt.id_prefix) |p| {
            if (std.mem.eql(u8, p, id_prefix)) return true;
        } else if (std.mem.eql(u8, nt.type, id_prefix)) {
            return true;
        }
    }
    return false;
}

/// Deprecated; use [`schemaHasIdPrefix`].
pub fn schemaHasObjPrefix(schema: *const TypeSchema, id_prefix: []const u8) bool {
    return schemaHasIdPrefix(schema, id_prefix);
}

fn openFile(io: Io, path: []const u8) !Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Io.Dir.openFileAbsolute(io, path, .{});
    }
    return Io.Dir.cwd().openFile(io, path, .{});
}
