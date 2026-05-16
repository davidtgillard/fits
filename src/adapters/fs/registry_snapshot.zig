//! Compare live `.fits/registry.json` type schema to a persona `registry.snapshot.json`.

const std = @import("std");
const fits_registry = @import("fits_registry.zig");
const registry_validate = @import("registry_validate.zig");

const Io = std.Io;

const SnapshotJson = struct {
    prefixes: []PrefixJson = &.{},
    link_types: []LinkTypeJson = &.{},
};

const PrefixJson = struct {
    obj_prefix: []const u8,
};

const LinkTypeJson = struct {
    link_type: []const u8,
    in_obj_prefix: []const u8,
    out_obj_prefix: []const u8,
};

/// Type-only schema extracted from a registry document.
pub const TypeSchema = struct {
    prefixes: []const []const u8,
    link_types: []LinkTypeEntry,

    pub const LinkTypeEntry = struct {
        link_type: []const u8,
        in_obj_prefix: []const u8,
        out_obj_prefix: []const u8,
    };

    pub fn deinit(self: *TypeSchema, allocator: std.mem.Allocator) void {
        for (self.prefixes) |p| allocator.free(p);
        allocator.free(self.prefixes);
        for (self.link_types) |*lt| {
            allocator.free(lt.link_type);
            allocator.free(lt.in_obj_prefix);
            allocator.free(lt.out_obj_prefix);
        }
        allocator.free(self.link_types);
        self.* = undefined;
    }
};

/// Loads snapshot schema from `package_root`/`snapshot_rel`.
pub fn loadTypeSchema(
    allocator: std.mem.Allocator,
    io: Io,
    package_root: []const u8,
    snapshot_rel: []const u8,
) !TypeSchema {
    const path = try std.fs.path.join(allocator, &.{ package_root, snapshot_rel });
    defer allocator.free(path);

    var file = openFile(io, path) catch |err| switch (err) {
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

    var prefixes: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |p| allocator.free(p);
        prefixes.deinit(allocator);
    }
    for (parsed.value.prefixes) |pj| {
        try prefixes.append(allocator, try allocator.dupe(u8, pj.obj_prefix));
    }

    var links: std.ArrayListUnmanaged(TypeSchema.LinkTypeEntry) = .empty;
    errdefer {
        for (links.items) |*lt| {
            allocator.free(lt.link_type);
            allocator.free(lt.in_obj_prefix);
            allocator.free(lt.out_obj_prefix);
        }
        links.deinit(allocator);
    }
    for (parsed.value.link_types) |lj| {
        try links.append(allocator, .{
            .link_type = try allocator.dupe(u8, lj.link_type),
            .in_obj_prefix = try allocator.dupe(u8, lj.in_obj_prefix),
            .out_obj_prefix = try allocator.dupe(u8, lj.out_obj_prefix),
        });
    }

    return .{
        .prefixes = try prefixes.toOwnedSlice(allocator),
        .link_types = try links.toOwnedSlice(allocator),
    };
}

/// Verifies live registry types match the snapshot (ignores counters and tombstones).
pub fn verifyRegistryMatchesSchema(reg: *const fits_registry.Registry, schema: *const TypeSchema) !void {
    if (reg.prefixes.items.len != schema.prefixes.len) return error.RegistrySnapshotMismatch;
    for (schema.prefixes) |sp| {
        if (!reg.hasObjPrefix(sp)) return error.RegistrySnapshotMismatch;
    }
    for (reg.prefixes.items) |live| {
        var found = false;
        for (schema.prefixes) |sp| {
            if (std.mem.eql(u8, live.obj_prefix, sp)) {
                found = true;
                break;
            }
        }
        if (!found) return error.RegistrySnapshotMismatch;
    }

    if (reg.link_types.items.len != schema.link_types.len) return error.RegistrySnapshotMismatch;
    for (schema.link_types) |sl| {
        const in_p = reg.linkTypeInPrefix(sl.link_type) orelse return error.RegistrySnapshotMismatch;
        const out_p = reg.linkTypeOutPrefix(sl.link_type) orelse return error.RegistrySnapshotMismatch;
        if (!std.mem.eql(u8, in_p, sl.in_obj_prefix)) return error.RegistrySnapshotMismatch;
        if (!std.mem.eql(u8, out_p, sl.out_obj_prefix)) return error.RegistrySnapshotMismatch;
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

/// Loads schema and verifies `reg` in one step.
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

/// Returns true when `obj_prefix` is declared in the snapshot schema.
pub fn schemaHasObjPrefix(schema: *const TypeSchema, obj_prefix: []const u8) bool {
    for (schema.prefixes) |p| {
        if (std.mem.eql(u8, p, obj_prefix)) return true;
    }
    return false;
}

fn openFile(io: Io, path: []const u8) !Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Io.Dir.openFileAbsolute(io, path, .{});
    }
    return Io.Dir.cwd().openFile(io, path, .{});
}
