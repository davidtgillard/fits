//! Parse and validate `persona.toml` for a persona package.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

pub const RegistryMode = enum {
    fixed,
    mutable,
};

pub const ExtensionDef = struct {
    name: []const u8,
    summary: []const u8,
    run_argv: []const []const u8,
};

pub const ValidateHookDef = struct {
    nodes_argv: []const []const u8,
    links_argv: []const []const u8,
    timeout_secs: u64 = 0,
};

/// Parsed `persona.toml` (owned strings).
pub const PersonaManifest = struct {
    id: []const u8,
    version: []const u8,
    fits_min_version: []const u8,
    description: []const u8,
    commands_allow: []const []const u8,
    extensions: []const ExtensionDef,
    registry_mode: RegistryMode,
    snapshot_rel: []const u8,
    validate_hooks_default: bool,
    validate_include_link_endpoints: bool,
    validate_hooks: []const ValidateHookDef,

    pub fn deinit(self: *PersonaManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.version);
        allocator.free(self.fits_min_version);
        allocator.free(self.description);
        for (self.commands_allow) |s| allocator.free(s);
        allocator.free(self.commands_allow);
        for (self.extensions) |*ext| {
            allocator.free(ext.name);
            allocator.free(ext.summary);
            for (ext.run_argv) |a| allocator.free(a);
            allocator.free(ext.run_argv);
        }
        allocator.free(self.extensions);
        allocator.free(self.snapshot_rel);
        for (self.validate_hooks) |*h| {
            for (h.nodes_argv) |a| allocator.free(a);
            allocator.free(h.nodes_argv);
            for (h.links_argv) |a| allocator.free(a);
            allocator.free(h.links_argv);
        }
        allocator.free(self.validate_hooks);
        self.* = undefined;
    }

    /// Returns extension by name, if declared.
    pub fn extensionByName(self: *const PersonaManifest, name: []const u8) ?*const ExtensionDef {
        for (self.extensions) |*ext| {
            if (std.mem.eql(u8, ext.name, name)) return ext;
        }
        return null;
    }

    /// Merged hook config for validate (first hook block, persona package paths resolved by caller).
    pub fn primaryHook(self: *const PersonaManifest) ?*const ValidateHookDef {
        if (self.validate_hooks.len == 0) return null;
        return &self.validate_hooks[0];
    }
};

/// Loads `persona.toml` from `package_root/persona.toml`.
pub fn loadFromPackageRoot(allocator: std.mem.Allocator, io: Io, package_root: []const u8) !PersonaManifest {
    const path = try std.fs.path.join(allocator, &.{ package_root, "persona.toml" });
    defer allocator.free(path);
    return loadFromFile(allocator, io, path, package_root);
}

/// Loads and validates a manifest file.
pub fn loadFromFile(allocator: std.mem.Allocator, io: Io, manifest_path: []const u8, package_root: []const u8) !PersonaManifest {
    var file = openFile(io, manifest_path) catch |err| switch (err) {
        error.FileNotFound => return error.PersonaManifestNotFound,
        else => |e| return e,
    };
    defer file.close(io);

    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > 1024 * 1024) return error.FileTooBig;
    const raw = try allocator.alloc(u8, n);
    defer allocator.free(raw);
    const got = try file.readPositionalAll(io, raw, 0);
    if (got != n) return error.UnexpectedEndOfFile;

    var manifest = try parseContents(allocator, raw);
    errdefer manifest.deinit(allocator);

    if (!isVersionCompatible(build_options.fits_version, manifest.fits_min_version)) {
        return error.PersonaVersionIncompatible;
    }

    if (manifest.registry_mode == .fixed and manifest.snapshot_rel.len == 0) {
        return error.InvalidPersonaManifest;
    }

    const snap_path = try std.fs.path.join(allocator, &.{ package_root, manifest.snapshot_rel });
    defer allocator.free(snap_path);
    if (manifest.registry_mode == .fixed) {
        _ = openFile(io, snap_path) catch |err| switch (err) {
            error.FileNotFound => return error.PersonaSnapshotNotFound,
            else => |e| return e,
        };
    }

    return manifest;
}

/// Compares `fits_version` against required `min_version` (numeric dot-separated components).
pub fn isVersionCompatible(fits_version: []const u8, min_version: []const u8) bool {
    var fits_parts: [8]u32 = undefined;
    var min_parts: [8]u32 = undefined;
    const fits_n = parseVersionParts(fits_version, &fits_parts);
    const min_n = parseVersionParts(min_version, &min_parts);
    const n = @max(fits_n, min_n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f: u32 = if (i < fits_n) fits_parts[i] else 0;
        const m: u32 = if (i < min_n) min_parts[i] else 0;
        if (f > m) return true;
        if (f < m) return false;
    }
    return true;
}

fn parseVersionParts(text: []const u8, out: *[8]u32) usize {
    var count: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '.' or i == text.len - 1) {
            const end = if (c == '.') i else i + 1;
            const slice = std.mem.trim(u8, text[start..end], " \t");
            if (slice.len > 0 and count < out.len) {
                out[count] = std.fmt.parseInt(u32, slice, 10) catch 0;
                count += 1;
            }
            start = i + 1;
        }
    }
    return count;
}

fn parseContents(allocator: std.mem.Allocator, raw: []const u8) !PersonaManifest {
    var id: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var fits_min: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var commands_allow_raw: ?[]const u8 = null;
    var registry_mode: RegistryMode = .fixed;
    var snapshot_rel: ?[]const u8 = null;
    var hooks_default = true;
    var include_link_endpoints = true;

    var extensions: std.ArrayListUnmanaged(ExtensionDef) = .empty;
    errdefer {
        for (extensions.items) |*ext| {
            allocator.free(ext.name);
            allocator.free(ext.summary);
            for (ext.run_argv) |a| allocator.free(a);
            allocator.free(ext.run_argv);
        }
        extensions.deinit(allocator);
    }

    var validate_hooks: std.ArrayListUnmanaged(ValidateHookDef) = .empty;
    errdefer {
        for (validate_hooks.items) |*h| {
            for (h.nodes_argv) |a| allocator.free(a);
            allocator.free(h.nodes_argv);
            for (h.links_argv) |a| allocator.free(a);
            allocator.free(h.links_argv);
        }
        validate_hooks.deinit(allocator);
    }

    var cur_ext: ?ExtensionDef = null;
    var cur_hook: ?ValidateHookDef = null;

    defer {
        if (commands_allow_raw) |p| allocator.free(p);
    }

    var section: enum { top, cli, commands, registry, validate } = .top;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = trimComment(raw_line);
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "[[commands.extension]]")) {
            if (cur_ext) |ext| try extensions.append(allocator, ext);
            cur_ext = ExtensionDef{ .name = "", .summary = "", .run_argv = &.{} };
            section = .commands;
            continue;
        }
        if (std.mem.startsWith(u8, line, "[[validate.hook]]")) {
            if (cur_hook) |h| try validate_hooks.append(allocator, h);
            cur_hook = ValidateHookDef{ .nodes_argv = &.{}, .links_argv = &.{}, .timeout_secs = 0 };
            section = .validate;
            continue;
        }
        if (line[0] == '[') {
            if (cur_ext) |ext| {
                try extensions.append(allocator, ext);
                cur_ext = null;
            }
            if (cur_hook) |h| {
                try validate_hooks.append(allocator, h);
                cur_hook = null;
            }
            if (std.mem.eql(u8, line, "[cli]")) {
                section = .cli;
                continue;
            }
            if (std.mem.eql(u8, line, "[commands]")) {
                section = .commands;
                continue;
            }
            if (std.mem.eql(u8, line, "[registry]")) {
                section = .registry;
                continue;
            }
            if (std.mem.eql(u8, line, "[validate]")) {
                section = .validate;
                continue;
            }
            section = .top;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");

        switch (section) {
            .top => {
                if (std.mem.eql(u8, key, "id")) id = try dupTomlString(allocator, val);
                if (std.mem.eql(u8, key, "version")) version = try dupTomlString(allocator, val);
                if (std.mem.eql(u8, key, "fits_min_version")) fits_min = try dupTomlString(allocator, val);
            },
            .cli => {
                if (std.mem.eql(u8, key, "description")) description = try dupTomlString(allocator, val);
            },
            .commands => {
                if (cur_ext != null) {
                    var ext = cur_ext.?;
                    if (std.mem.eql(u8, key, "name")) {
                        ext.name = try dupTomlString(allocator, val);
                    } else if (std.mem.eql(u8, key, "summary")) {
                        ext.summary = try dupTomlString(allocator, val);
                    } else if (std.mem.eql(u8, key, "run")) {
                        ext.run_argv = try parseJsonArgv(allocator, val);
                    }
                    cur_ext = ext;
                } else if (std.mem.eql(u8, key, "allow")) {
                    if (commands_allow_raw) |p| allocator.free(p);
                    commands_allow_raw = try allocator.dupe(u8, val);
                }
            },
            .registry => {
                if (std.mem.eql(u8, key, "mode")) {
                    registry_mode = if (std.mem.eql(u8, val, "mutable")) .mutable else .fixed;
                } else if (std.mem.eql(u8, key, "snapshot")) {
                    snapshot_rel = try dupTomlString(allocator, val);
                }
            },
            .validate => {
                if (cur_hook != null) {
                    var h = cur_hook.?;
                    if (std.mem.eql(u8, key, "nodes_command")) {
                        h.nodes_argv = try parseJsonArgv(allocator, val);
                    } else if (std.mem.eql(u8, key, "links_command")) {
                        h.links_argv = try parseJsonArgv(allocator, val);
                    } else if (std.mem.eql(u8, key, "timeout_secs")) {
                        h.timeout_secs = std.fmt.parseInt(u64, val, 10) catch 0;
                    }
                    cur_hook = h;
                } else {
                    if (std.mem.eql(u8, key, "hooks_default")) {
                        hooks_default = std.mem.eql(u8, val, "true");
                    } else if (std.mem.eql(u8, key, "include_link_endpoints")) {
                        include_link_endpoints = std.mem.eql(u8, val, "true");
                    }
                }
            },
        }
    }

    if (cur_ext) |ext| try extensions.append(allocator, ext);
    if (cur_hook) |h| try validate_hooks.append(allocator, h);

    const id_final = id orelse return error.InvalidPersonaManifest;
    const version_final = version orelse return error.InvalidPersonaManifest;

    const allow = try parseJsonArgv(allocator, commands_allow_raw orelse "[]");
    errdefer freeArgv(allocator, allow);

    const fits_min_owned = if (fits_min) |f| f else try allocator.dupe(u8, "0.0.0");
    const desc_owned = if (description) |d| d else try allocator.dupe(u8, "");
    const snap_owned = if (snapshot_rel) |s| s else try allocator.dupe(u8, "registry.snapshot.json");

    return PersonaManifest{
        .id = id_final,
        .version = version_final,
        .fits_min_version = fits_min_owned,
        .description = desc_owned,
        .commands_allow = allow,
        .extensions = try extensions.toOwnedSlice(allocator),
        .registry_mode = registry_mode,
        .snapshot_rel = snap_owned,
        .validate_hooks_default = hooks_default,
        .validate_include_link_endpoints = include_link_endpoints,
        .validate_hooks = try validate_hooks.toOwnedSlice(allocator),
    };
}

fn dupTomlString(allocator: std.mem.Allocator, val: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
    }
    return try allocator.dupe(u8, trimmed);
}

fn parseJsonArgv(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return &[_][]const u8{};
    var parsed = try std.json.parseFromSlice([][]const u8, allocator, trimmed, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const duped = try allocator.alloc([]const u8, parsed.value.len);
    for (parsed.value, 0..) |s, i| {
        duped[i] = try allocator.dupe(u8, s);
    }
    return duped;
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |s| allocator.free(s);
    allocator.free(argv);
}

fn trimComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse return std.mem.trim(u8, line, " \t\r");
    return std.mem.trim(u8, line[0..hash], " \t\r");
}

fn openFile(io: Io, path: []const u8) !Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Io.Dir.openFileAbsolute(io, path, .{});
    }
    return Io.Dir.cwd().openFile(io, path, .{});
}

test "version compatible" {
    try std.testing.expect(isVersionCompatible("0.2.0", "0.1.0"));
    try std.testing.expect(!isVersionCompatible("0.1.0", "0.2.0"));
}
