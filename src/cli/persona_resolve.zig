//! Resolve a persona package from `argv[0]` and filesystem search paths.

const std = @import("std");
const persona = @import("persona.zig");
const persona_manifest = @import("persona_manifest.zig");
const fits_zon = @import("../adapters/fs/fits_zon.zig");

const Io = std.Io;
const ResolvedPersona = persona.ResolvedPersona;

/// Extracts the executable basename from `argv0` (strips path and optional `.exe`).
pub fn basenameFromArgv0(argv0: []const u8) []const u8 {
    const base = std.fs.path.basename(argv0);
    if (std.mem.endsWith(u8, base, ".exe")) return base[0 .. base.len - 4];
    return base;
}

/// Resolves persona for this process. Default when basename is `fits`.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    argv0: []const u8,
    cwd: []const u8,
) !ResolvedPersona {
    const name = basenameFromArgv0(argv0);
    if (std.mem.eql(u8, name, "fits")) {
        return persona.defaultPersona(allocator);
    }
    return resolveNamed(allocator, io, environ, name, cwd);
}

fn resolveNamed(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    persona_id: []const u8,
    cwd: []const u8,
) !ResolvedPersona {
    const package_root = findPackageRoot(allocator, io, environ, persona_id, cwd) orelse {
        if (!builtin.is_test) {
            std.debug.print(
                "persona '{s}' not found; install with `fits persona install <path>`\n",
                .{persona_id},
            );
        }
        return error.PersonaNotFound;
    };
    defer allocator.free(package_root);

    fits_zon.checkRepoPersonaBinding(allocator, io, cwd, persona_id) catch |err| switch (err) {
        error.PersonaRepoMismatch => return err,
        else => {},
    };

    var manifest = try persona_manifest.loadFromPackageRoot(allocator, io, package_root);
    errdefer manifest.deinit(allocator);

    if (!std.mem.eql(u8, manifest.id, persona_id)) {
        if (!builtin.is_test) {
            std.debug.print(
                "persona manifest id '{s}' does not match executable name '{s}'\n",
                .{ manifest.id, persona_id },
            );
        }
        return error.PersonaIdMismatch;
    }

    const owned_root = try allocator.dupe(u8, package_root);
    return ResolvedPersona{
        .id = manifest.id,
        .is_default = false,
        .package_root = owned_root,
        .manifest = manifest,
    };
}

const builtin = @import("builtin");

fn findPackageRoot(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    persona_id: []const u8,
    cwd: []const u8,
) ?[]const u8 {
    if (findRepoLocal(allocator, io, environ, persona_id, cwd)) |p| return p;
    if (findGlobal(allocator, io, environ, persona_id)) |p| return p;
    if (findEnvPath(allocator, io, environ, persona_id)) |p| return p;
    return null;
}

fn findRepoLocal(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    persona_id: []const u8,
    start_cwd: []const u8,
) ?[]const u8 {
    var dir_path = std.mem.Allocator.dupe(allocator, u8, start_cwd) catch return null;
    defer allocator.free(dir_path);

    while (true) {
        const persona_path = std.fs.path.join(allocator, &.{ dir_path, ".fits", "personas", persona_id, "persona.toml" }) catch return null;
        defer allocator.free(persona_path);
        if (pathExists(io, persona_path)) {
            const root = std.fs.path.join(allocator, &.{ dir_path, ".fits", "personas", persona_id }) catch return null;
            return root;
        }

        const zon_path = std.fs.path.join(allocator, &.{ dir_path, "fits.zon" }) catch return null;
        defer allocator.free(zon_path);
        if (pathExists(io, zon_path)) {
            if (fits_zon.readPersonaId(allocator, io, zon_path)) |zon_id| {
                defer allocator.free(zon_id);
                if (std.mem.eql(u8, zon_id, persona_id)) {
                    if (findGlobal(allocator, io, environ, persona_id)) |g| return g;
                    if (findEnvPath(allocator, io, environ, persona_id)) |e| return e;
                }
            } else |_| {}
        }

        const parent = std.fs.path.dirname(dir_path) orelse break;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir_path)) break;
        const next = std.mem.Allocator.dupe(allocator, u8, parent) catch break;
        allocator.free(dir_path);
        dir_path = next;
    }
    return null;
}

fn findGlobal(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, persona_id: []const u8) ?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    const path = std.fs.path.join(allocator, &.{ home, ".config", "fits", "personas", persona_id, "persona.toml" }) catch return null;
    defer allocator.free(path);
    if (!pathExists(io, path)) return null;
    return std.fs.path.join(allocator, &.{ home, ".config", "fits", "personas", persona_id }) catch null;
}

fn findEnvPath(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, persona_id: []const u8) ?[]const u8 {
    const base = environ.get("FITS_PERSONA_PATH") orelse return null;
    const path = std.fs.path.join(allocator, &.{ base, persona_id, "persona.toml" }) catch return null;
    defer allocator.free(path);
    if (!pathExists(io, path)) return null;
    return std.fs.path.join(allocator, &.{ base, persona_id }) catch null;
}

fn pathExists(io: Io, path: []const u8) bool {
    const st = if (std.fs.path.isAbsolute(path))
        Io.Dir.openFileAbsolute(io, path, .{}) catch return false
    else
        Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    st.close(io);
    return true;
}
