//! CLI use-case: create a new object under `objects/` using the machine-owned registry.
//! IDs are never reused after deletion: counters in `.fits/registry.json` only increase.
//! The object type prefix must be registered first via `fits register obj-type`.

const builtin = @import("builtin");
const std = @import("std");
const fits_config = @import("../adapters/fs/fits_config.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");

/// Default repository root when the CLI is run from the project tree.
pub const default_repo_root: []const u8 = ".";

/// Default objects directory name under the repository root (matches validate).
pub const default_objects_dir: []const u8 = "objects";

/// Options for [`run`].
pub const NewOptions = struct {
    /// When true, create a markdown file; otherwise create an empty directory.
    markdown: bool = false,
    /// Words joined with spaces for the human suffix after `{obj_prefix}-{n}` (may be empty).
    title_words: []const []const u8 = &.{},
};

/// Creates a new object with id `{obj_prefix}-{n}` where `n` comes from the registry (never padded).
///
/// Persists the updated registry before touching `objects/` so concurrent runs still advance
/// the counter even if directory creation fails (the numeric id is considered consumed).
///
/// Parameters:
/// - `allocator`: Used for path buffers and formatted names.
/// - `io`: Process I/O implementation for filesystem operations.
/// - `repo_root`: Repository root (`.` or an absolute path); `.fits/registry.json` lives here.
/// - `objects_rel`: Directory under `repo_root` where the object is created (typically `objects`).
/// - `obj_prefix`: User prefix such as `REQ` (must be registered; validated by [`fits_registry.validateObjPrefix`]).
/// - `options`: Markdown vs folder and optional title words after `--`.
///
/// Returns: nothing on success.
/// On failure: [`fits_registry.validateObjPrefix`] errors, [`error.UnknownObjPrefix`], title validation, registry I/O, or filesystem errors.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    objects_rel: []const u8,
    obj_prefix: []const u8,
    options: NewOptions,
) !void {
    try fits_registry.validateObjPrefix(obj_prefix);
    for (options.title_words) |w| {
        try validateTitleWord(w);
    }

    var prefs = try fits_config.loadParsedConfigForRepo(allocator, io, repo_root);
    defer prefs.deinit();

    var use_markdown = options.markdown;
    if (!options.markdown) {
        if (prefs.objCreateFolder(obj_prefix)) |cf| {
            if (!cf) use_markdown = true;
        }
    }

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    if (!reg.hasObjPrefix(obj_prefix)) return error.UnknownObjPrefix;

    const n = try reg.allocateNextNumeric(obj_prefix);
    try reg.save(io, repo_root);

    const display_name = try formatDisplayName(allocator, obj_prefix, n, options.title_words);
    defer allocator.free(display_name);

    const cwd = std.Io.Dir.cwd();
    const objects_dir_path = try std.fs.path.join(allocator, &.{ repo_root, objects_rel });
    defer allocator.free(objects_dir_path);
    try cwd.createDirPath(io, objects_dir_path);

    if (use_markdown) {
        const file_name = try std.mem.concat(allocator, u8, &.{ display_name, ".md" });
        defer allocator.free(file_name);
        const file_path = try std.fs.path.join(allocator, &.{ objects_dir_path, file_name });
        defer allocator.free(file_path);
        const f = try cwd.createFile(io, file_path, .{ .read = false, .truncate = true, .exclusive = true });
        defer f.close(io);

        const line = try std.fs.path.join(allocator, &.{ objects_rel, file_name });
        defer allocator.free(line);
        if (!builtin.is_test) std.debug.print("Created {s}\n", .{line});
    } else {
        const dir_path = try std.fs.path.join(allocator, &.{ objects_dir_path, display_name });
        defer allocator.free(dir_path);
        try cwd.createDirPath(io, dir_path);

        const line = try std.fs.path.join(allocator, &.{ objects_rel, display_name });
        defer allocator.free(line);
        if (!builtin.is_test) std.debug.print("Created {s}/\n", .{line});
    }
}

fn validateTitleWord(word: []const u8) !void {
    if (word.len == 0) return error.InvalidTitle;
    for (word) |c| {
        if (c == '/' or c == '\\') return error.InvalidTitle;
        if (std.ascii.isControl(c)) return error.InvalidTitle;
    }
}

fn formatDisplayName(
    allocator: std.mem.Allocator,
    obj_prefix: []const u8,
    n: u64,
    title_words: []const []const u8,
) ![]const u8 {
    if (title_words.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}-{d}", .{ obj_prefix, n });
    }
    const title = try std.mem.join(allocator, " ", title_words);
    defer allocator.free(title);
    return std.fmt.allocPrint(allocator, "{s}-{d} {s}", .{ obj_prefix, n, title });
}

test "formatDisplayName" {
    const a = std.testing.allocator;
    const s = try formatDisplayName(a, "REQ", 12, &.{});
    defer a.free(s);
    try std.testing.expectEqualStrings("REQ-12", s);

    const t = try formatDisplayName(a, "REQ", 3, &.{ "Login", "flow" });
    defer a.free(t);
    try std.testing.expectEqualStrings("REQ-3 Login flow", t);
}
