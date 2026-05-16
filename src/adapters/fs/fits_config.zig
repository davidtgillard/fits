//! User-editable `fits` CLI settings under `.fits/fits_config.toml` or global XDG config.
//! Supports per object-type and per link-type `create_folder` preferences in dedicated tables.

const std = @import("std");
const fits_registry = @import("fits_registry.zig");

const Io = std.Io;
const Dir = Io.Dir;

pub const config_file_name: []const u8 = "fits_config.toml";

/// Default background update check interval (seconds).
pub const default_update_check_time_period: u64 = 86400;

/// Minimal config (update check period only).
pub const Config = struct {
    update_check_time_period: u64,
};

/// Parsed repository config including optional per-type folder preferences.
pub const ParsedConfig = struct {
    allocator: std.mem.Allocator,
    update_check_time_period: u64,
    obj_type_create_folder: std.StringHashMapUnmanaged(bool) = .empty,
    link_type_create_folder: std.StringHashMapUnmanaged(bool) = .empty,

    /// Frees duplicated table keys.
    pub fn deinit(self: *ParsedConfig) void {
        var oi = self.obj_type_create_folder.keyIterator();
        while (oi.next()) |k| self.allocator.free(k.*);
        self.obj_type_create_folder.deinit(self.allocator);
        var li = self.link_type_create_folder.keyIterator();
        while (li.next()) |k| self.allocator.free(k.*);
        self.link_type_create_folder.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns `null` when the user has not set a preference for `prefix`.
    pub fn objCreateFolder(self: *const ParsedConfig, prefix: []const u8) ?bool {
        return self.obj_type_create_folder.get(prefix);
    }

    /// Returns `null` when the user has not set a preference for `link_type`.
    pub fn linkCreateFolder(self: *const ParsedConfig, link_type: []const u8) ?bool {
        return self.link_type_create_folder.get(link_type);
    }

    pub fn setObjCreateFolder(self: *ParsedConfig, prefix: []const u8, value: bool) !void {
        if (self.obj_type_create_folder.fetchRemove(prefix)) |kv| self.allocator.free(kv.key);
        const k = try self.allocator.dupe(u8, prefix);
        errdefer self.allocator.free(k);
        try self.obj_type_create_folder.put(self.allocator, k, value);
    }

    pub fn setLinkCreateFolder(self: *ParsedConfig, link_type: []const u8, value: bool) !void {
        if (self.link_type_create_folder.fetchRemove(link_type)) |kv| self.allocator.free(kv.key);
        const k = try self.allocator.dupe(u8, link_type);
        errdefer self.allocator.free(k);
        try self.link_type_create_folder.put(self.allocator, k, value);
    }

    /// Renames a `link_types` table key after `fits register rename-type` on a link type.
    pub fn renameLinkTypeKey(self: *ParsedConfig, old_name: []const u8, new_name: []const u8) !void {
        if (std.mem.eql(u8, old_name, new_name)) return;
        const v = self.link_type_create_folder.fetchRemove(old_name) orelse return;
        defer self.allocator.free(v.key);
        try self.setLinkCreateFolder(new_name, v.value);
    }
};

/// Returns true when `path` is an existing directory.
pub fn fitsDirExists(cwd: Dir, io: Io, path: []const u8) bool {
    const st = cwd.statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Joins `{repo_root}/.fits/fits_config.toml` (caller frees).
pub fn joinRepoFitsConfigPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        repo_root,
        fits_registry.fits_dir_name,
        config_file_name,
    });
}

/// Resolves the config file path (caller frees).
///
/// If `{cwd}/.fits/` exists, use `{cwd}/.fits/fits_config.toml`.
/// Otherwise `$XDG_CONFIG_HOME/fits/fits_config.toml` (fallback `~/.config/fits/`).
pub fn resolveConfigPath(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    cwd_rel: []const u8,
) ![]const u8 {
    const fits_rel = try std.fs.path.join(allocator, &.{ cwd_rel, fits_registry.fits_dir_name });
    defer allocator.free(fits_rel);

    const cwd = Dir.cwd();
    if (fitsDirExists(cwd, io, fits_rel)) {
        return std.fs.path.join(allocator, &.{ fits_rel, config_file_name });
    }
    return globalConfigPath(allocator, environ);
}

fn globalConfigPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |base| {
        return std.fs.path.join(allocator, &.{ base, "fits", config_file_name });
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, ".config", "fits", config_file_name });
}

/// Loads config or creates the file with defaults when missing.
pub fn loadOrCreateDefault(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !Config {
    const path = try resolveConfigPath(allocator, io, environ, ".");
    defer allocator.free(path);

    const cwd = Dir.cwd();
    if (cwd.statFile(io, path, .{})) |_| {
        const text = try readFileAllocPath(io, allocator, path, 256 * 1024);
        defer allocator.free(text);
        var pc = parseFullConfig(allocator, text) catch |err| {
            std.debug.print("invalid {s}: malformed config\n", .{path});
            return err;
        };
        defer pc.deinit();
        return .{ .update_check_time_period = pc.update_check_time_period };
    } else |_| {
        var pc = ParsedConfig{
            .allocator = allocator,
            .update_check_time_period = default_update_check_time_period,
        };
        defer pc.deinit();
        try writeParsedConfig(io, allocator, path, &pc);
        return .{ .update_check_time_period = default_update_check_time_period };
    }
}

/// Loads `.fits/fits_config.toml` under `repo_root`, or defaults when missing or `.fits` absent.
pub fn loadParsedConfigForRepo(self_allocator: std.mem.Allocator, io: Io, repo_root: []const u8) !ParsedConfig {
    const cwd = Dir.cwd();
    const fits_rel = try std.fs.path.join(self_allocator, &.{ repo_root, fits_registry.fits_dir_name });
    defer self_allocator.free(fits_rel);
    if (!fitsDirExists(cwd, io, fits_rel)) {
        return ParsedConfig{
            .allocator = self_allocator,
            .update_check_time_period = default_update_check_time_period,
        };
    }
    const path = try joinRepoFitsConfigPath(self_allocator, repo_root);
    defer self_allocator.free(path);
    return loadParsedConfigFile(self_allocator, io, path);
}

/// Loads a config file by path; missing file yields defaults.
pub fn loadParsedConfigFile(allocator: std.mem.Allocator, io: Io, path: []const u8) !ParsedConfig {
    const text = readFileAllocPath(io, allocator, path, 256 * 1024) catch |err| switch (err) {
        error.FileNotFound => return ParsedConfig{
            .allocator = allocator,
            .update_check_time_period = default_update_check_time_period,
        },
        else => |e| return e,
    };
    defer allocator.free(text);
    return parseFullConfig(allocator, text);
}

/// Ensures `{repo_root}/.fits/` exists and merges `create_folder` for an object type into config.
pub fn mergeRepoObjTypeCreateFolder(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    obj_prefix: []const u8,
    create_folder: bool,
) !void {
    const cwd = Dir.cwd();
    const fits_rel = try std.fs.path.join(allocator, &.{ repo_root, fits_registry.fits_dir_name });
    defer allocator.free(fits_rel);
    try cwd.createDirPath(io, fits_rel);

    const path = try joinRepoFitsConfigPath(allocator, repo_root);
    defer allocator.free(path);

    var pc = try loadParsedConfigFile(allocator, io, path);
    defer pc.deinit();

    try pc.setObjCreateFolder(obj_prefix, create_folder);
    try writeParsedConfig(io, allocator, path, &pc);
}

/// Ensures `{repo_root}/.fits/` exists and merges `create_folder` for a link type into config.
pub fn mergeRepoLinkTypeCreateFolder(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    link_type: []const u8,
    create_folder: bool,
) !void {
    const cwd = Dir.cwd();
    const fits_rel = try std.fs.path.join(allocator, &.{ repo_root, fits_registry.fits_dir_name });
    defer allocator.free(fits_rel);
    try cwd.createDirPath(io, fits_rel);

    const path = try joinRepoFitsConfigPath(allocator, repo_root);
    defer allocator.free(path);

    var pc = try loadParsedConfigFile(allocator, io, path);
    defer pc.deinit();

    try pc.setLinkCreateFolder(link_type, create_folder);
    try writeParsedConfig(io, allocator, path, &pc);
}

/// Renames `[obj_types.OLD]` preferences to `[obj_types.NEW]` when renaming an object type.
pub fn renameRepoObjTypeCreateFolderKey(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    old_prefix: []const u8,
    new_prefix: []const u8,
) !void {
    const path = try joinRepoFitsConfigPath(allocator, repo_root);
    defer allocator.free(path);

    var pc = try loadParsedConfigFile(allocator, io, path);
    defer pc.deinit();

    const v = pc.obj_type_create_folder.fetchRemove(old_prefix) orelse return;
    defer pc.allocator.free(v.key);
    try pc.setObjCreateFolder(new_prefix, v.value);
    try writeParsedConfig(io, allocator, path, &pc);
}

/// Removes `[obj_types.PREFIX]` from repo config when present.
pub fn removeRepoObjTypeCreateFolderKey(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    obj_prefix: []const u8,
) !void {
    const path = try joinRepoFitsConfigPath(allocator, repo_root);
    defer allocator.free(path);

    var pc = try loadParsedConfigFile(allocator, io, path);
    defer pc.deinit();

    const v = pc.obj_type_create_folder.fetchRemove(obj_prefix) orelse return;
    defer pc.allocator.free(v.key);
    try writeParsedConfig(io, allocator, path, &pc);
}

/// Removes `[link_types.LINK_TYPE]` from repo config when present.
pub fn removeRepoLinkTypeCreateFolderKey(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    link_type: []const u8,
) !void {
    const path = try joinRepoFitsConfigPath(allocator, repo_root);
    defer allocator.free(path);

    var pc = try loadParsedConfigFile(allocator, io, path);
    defer pc.deinit();

    const v = pc.link_type_create_folder.fetchRemove(link_type) orelse return;
    defer pc.allocator.free(v.key);
    try writeParsedConfig(io, allocator, path, &pc);
}

/// Renames a `[link_types.OLD]` preferences block when renaming a link type.
pub fn renameRepoLinkTypeCreateFolderKey(
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    old_link_type: []const u8,
    new_link_type: []const u8,
) !void {
    const path = try joinRepoFitsConfigPath(allocator, repo_root);
    defer allocator.free(path);

    var pc = try loadParsedConfigFile(allocator, io, path);
    defer pc.deinit();

    try pc.renameLinkTypeKey(old_link_type, new_link_type);
    try writeParsedConfig(io, allocator, path, &pc);
}

/// Writes [`ParsedConfig`] to `path` atomically (canonical layout).
pub fn writeParsedConfig(io: Io, allocator: std.mem.Allocator, path: []const u8, cfg: *const ParsedConfig) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidConfig;
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, parent);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    try body.print(allocator, "# fits CLI settings (user-editable)\n", .{});
    try body.print(allocator, "update_check_time_period = {d}\n\n", .{cfg.update_check_time_period});

    {
        const keys = try copySortKeys(allocator, &cfg.obj_type_create_folder);
        defer {
            for (keys) |k| allocator.free(k);
            allocator.free(keys);
        }
        for (keys) |k| {
            const val = cfg.obj_type_create_folder.get(k).?;
            try body.print(allocator, "[obj_types.{s}]\n", .{k});
            try body.print(allocator, "create_folder = {s}\n\n", .{if (val) "true" else "false"});
        }
    }
    {
        const keys = try copySortKeys(allocator, &cfg.link_type_create_folder);
        defer {
            for (keys) |k| allocator.free(k);
            allocator.free(keys);
        }
        for (keys) |k| {
            const val = cfg.link_type_create_folder.get(k).?;
            try body.print(allocator, "[link_types.{s}]\n", .{k});
            try body.print(allocator, "create_folder = {s}\n\n", .{if (val) "true" else "false"});
        }
    }

    const tmp_path = try std.mem.concat(allocator, u8, &.{ path, ".tmp" });
    defer allocator.free(tmp_path);

    {
        var out = try cwd.createFile(io, tmp_path, .{ .read = false, .truncate = true, .exclusive = false });
        defer out.close(io);
        try out.writeStreamingAll(io, body.items);
        try out.sync(io);
    }
    try cwd.rename(tmp_path, cwd, path, io);
}

fn copySortKeys(allocator: std.mem.Allocator, map: *const std.StringHashMapUnmanaged(bool)) ![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |k| allocator.free(k);
        list.deinit(allocator);
    }
    var it = map.keyIterator();
    while (it.next()) |kp| {
        const k = try allocator.dupe(u8, kp.*);
        errdefer allocator.free(k);
        try list.append(allocator, k);
    }
    std.mem.sortUnstable([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return list.toOwnedSlice(allocator);
}

/// Returns whether a background update check should run now.
pub fn shouldRunBackgroundCheck(now_sec: i64, period_sec: u64, last_check_sec: i64) bool {
    if (last_check_sec <= 0) return true;
    const elapsed: u64 = if (now_sec > last_check_sec)
        @intCast(now_sec - last_check_sec)
    else
        0;
    return elapsed >= period_sec;
}

/// Parses full config including optional `[obj_types.X]` / `[link_types.Y]` sections.
pub fn parseFullConfig(allocator: std.mem.Allocator, text: []const u8) !ParsedConfig {
    var pc = ParsedConfig{
        .allocator = allocator,
        .update_check_time_period = default_update_check_time_period,
    };
    errdefer pc.deinit();

    const Section = enum { top, obj_type, link_type };
    var section: Section = .top;
    var table_key: ?[]const u8 = null;
    errdefer if (table_key) |k| allocator.free(k);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimComment(raw_line);
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (!std.mem.endsWith(u8, line, "]")) return error.InvalidConfig;
            const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (table_key) |k| {
                allocator.free(k);
                table_key = null;
            }
            if (std.mem.startsWith(u8, inner, "obj_types.")) {
                const key_part = inner["obj_types.".len..];
                if (key_part.len == 0) return error.InvalidConfig;
                section = .obj_type;
                table_key = try allocator.dupe(u8, key_part);
            } else if (std.mem.startsWith(u8, inner, "link_types.")) {
                const key_part = inner["link_types.".len..];
                if (key_part.len == 0) return error.InvalidConfig;
                section = .link_type;
                table_key = try allocator.dupe(u8, key_part);
            } else {
                section = .top;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "update_check_time_period")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const value_text = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            pc.update_check_time_period = parsePeriodValue(value_text) catch return error.InvalidConfig;
            continue;
        }

        if (std.mem.startsWith(u8, line, "create_folder")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const value_text = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            const b = parseBoolValue(value_text) orelse return error.InvalidConfig;
            const key = table_key orelse return error.InvalidConfig;
            switch (section) {
                .obj_type => try pc.setObjCreateFolder(key, b),
                .link_type => try pc.setLinkCreateFolder(key, b),
                .top => return error.InvalidConfig,
            }
            continue;
        }

        return error.InvalidConfig;
    }

    if (table_key) |k| allocator.free(k);
    table_key = null;

    const out = pc;
    pc = undefined;
    return out;
}

fn parseBoolValue(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

/// Parses TOML config text for [`Config`] only (caller passes allocator for scratch parsing).
pub fn parseConfig(allocator: std.mem.Allocator, text: []const u8) !Config {
    var pc = try parseFullConfig(allocator, text);
    defer pc.deinit();
    return .{ .update_check_time_period = pc.update_check_time_period };
}

fn parsePeriodValue(text: []const u8) !u64 {
    if (text.len >= 2 and text[text.len - 1] == 'd') {
        const num_text = std.mem.trim(u8, text[0 .. text.len - 1], " \t");
        const days = try std.fmt.parseInt(u64, num_text, 10);
        return std.math.mul(u64, days, 86400) catch return error.InvalidConfig;
    }
    return std.fmt.parseInt(u64, text, 10);
}

fn trimComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse return std.mem.trim(u8, line, " \t\r");
    return std.mem.trim(u8, line[0..hash], " \t\r");
}

fn readFileAllocPath(io: Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openPath(io, path);
    defer file.close(io);
    const st = try file.stat(io);
    const n = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    if (n > max_bytes) return error.FileTooBig;
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, 0);
    if (got != n) return error.UnexpectedEndOfFile;
    return buf;
}

fn openPath(io: Io, path: []const u8) Io.File.OpenError!Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return Dir.openFileAbsolute(io, path, .{});
    }
    return Dir.cwd().openFile(io, path, .{});
}

test "parse period with day suffix" {
    const cfg = try parseConfig(std.testing.allocator, "update_check_time_period = 1d\n");
    try std.testing.expectEqual(@as(u64, 86400), cfg.update_check_time_period);
}

test "parseFullConfig obj and link tables" {
    const a = std.testing.allocator;
    const text =
        \\update_check_time_period = 3600
        \\
        \\[obj_types.REQ]
        \\create_folder = false
        \\
        \\[link_types.impl]
        \\create_folder = true
        \\
    ;
    var pc = try parseFullConfig(a, text);
    defer pc.deinit();
    try std.testing.expectEqual(@as(u64, 3600), pc.update_check_time_period);
    try std.testing.expectEqual(@as(?bool, false), pc.objCreateFolder("REQ"));
    try std.testing.expectEqual(@as(?bool, true), pc.linkCreateFolder("impl"));
}

test "shouldRunBackgroundCheck gating" {
    try std.testing.expect(shouldRunBackgroundCheck(100_000, 86400, 0));
    try std.testing.expect(!shouldRunBackgroundCheck(100_000, 86400, 99_000));
    try std.testing.expect(shouldRunBackgroundCheck(200_000, 86400, 100_000));
}
