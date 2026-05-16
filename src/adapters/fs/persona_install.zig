//! Install persona packages under `~/.config/fits/personas/<id>/`.

const std = @import("std");
const persona_manifest = @import("../../cli/persona_manifest.zig");

const Io = std.Io;
const Dir = Io.Dir;

pub const personas_config_subpath = [_][]const u8{ ".config", "fits", "personas" };

/// Copies or symlinks `source_dir` to `~/.config/fits/personas/<id>/`.
pub fn install(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    source_dir: []const u8,
    link: bool,
) ![]const u8 {
    var manifest = try persona_manifest.loadFromPackageRoot(allocator, io, source_dir);
    defer manifest.deinit(allocator);

    const dest_parent = try globalPersonasDir(allocator, environ);
    defer allocator.free(dest_parent);
    try Dir.cwd().createDirPath(io, dest_parent);

    const dest = try std.fs.path.join(allocator, &.{ dest_parent, manifest.id });
    defer allocator.free(dest);

    if (pathExists(io, dest)) {
        if (!builtin.is_test) std.debug.print("persona '{s}' already installed at {s}\n", .{ manifest.id, dest });
        return error.PersonaAlreadyInstalled;
    }

    if (link) {
        const abs_source_z = try Dir.cwd().realPathFileAlloc(io, source_dir, allocator);
        defer allocator.free(abs_source_z);
        const abs_source: []const u8 = std.mem.sliceTo(abs_source_z, 0);
        Dir.cwd().symLink(io, abs_source, dest, .{ .is_directory = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.PersonaAlreadyInstalled,
            else => |e| return e,
        };
    } else {
        try copyDirRecursive(allocator, io, source_dir, dest);
    }

    if (!builtin.is_test) std.debug.print("installed persona '{s}' to {s}\n", .{ manifest.id, dest });
    return try allocator.dupe(u8, dest);
}

/// Lists installed persona ids under the global personas directory.
pub fn listInstalled(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) ![]const []const u8 {
    const parent = try globalPersonasDir(allocator, environ);
    defer allocator.free(parent);

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    var dir = Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc([]const u8, 0),
        else => |e| return e,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const manifest_path = try std.fs.path.join(allocator, &.{ parent, entry.name, "persona.toml" });
        defer allocator.free(manifest_path);
        if (!pathExistsFile(io, manifest_path)) continue;
        try list.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return try list.toOwnedSlice(allocator);
}

/// Prints manifest summary for an installed persona id.
pub fn printInfo(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, persona_id: []const u8) !void {
    const home = environ.get("HOME") orelse return error.NoHomeDir;
    const pkg = try std.fs.path.join(allocator, &.{ home, ".config", "fits", "personas", persona_id });
    defer allocator.free(pkg);

    var manifest = try persona_manifest.loadFromPackageRoot(allocator, io, pkg);
    defer manifest.deinit(allocator);

    std.debug.print("persona: {s}\nversion: {s}\nfits_min_version: {s}\npackage: {s}\n", .{
        manifest.id,
        manifest.version,
        manifest.fits_min_version,
        pkg,
    });
}

fn globalPersonasDir(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const home = environ.get("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{
        home,
        personas_config_subpath[0],
        personas_config_subpath[1],
        personas_config_subpath[2],
    });
}

fn pathExists(io: Io, path: []const u8) bool {
    var dir = Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn pathExistsFile(io: Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn copyDirRecursive(allocator: std.mem.Allocator, io: Io, src: []const u8, dest: []const u8) !void {
    try Dir.cwd().createDirPath(io, dest);
    var dir = try Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const src_child = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_child);
        const dest_child = try std.fs.path.join(allocator, &.{ dest, entry.name });
        defer allocator.free(dest_child);

        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, io, src_child, dest_child),
            .file => {
                try copyFile(allocator, io, src_child, dest_child);
            },
            else => {},
        }
    }
}

fn copyFile(allocator: std.mem.Allocator, io: Io, src_path: []const u8, dest_path: []const u8) !void {
    var src = try Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);
    const st = try src.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    const buf = try allocator.alloc(u8, n);
    defer allocator.free(buf);
    const got = try src.readPositionalAll(io, buf, 0);
    if (got != n) return error.UnexpectedEndOfFile;

    var dest = try Dir.cwd().createFile(io, dest_path, .{ .read = false, .truncate = true, .exclusive = false });
    defer dest.close(io);
    try dest.writeStreamingAll(io, buf);
    try dest.sync(io);
}

const builtin = @import("builtin");
