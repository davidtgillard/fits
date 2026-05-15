//! Removes a link instance: updates [`relations/links.jsonc`], tombstones in the registry, drops optional payload dir.

const builtin = @import("builtin");
const std = @import("std");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const instance_id = @import("../domain/instance_id.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const links_validate = @import("../adapters/fs/links_validate.zig");
const tombstone_cache = @import("../adapters/cache/tombstone_cache.zig");

pub const default_repo_root: []const u8 = ".";

/// Tombstones link `link_id`, removes its row from `relations/links.jsonc`, and deletes `relations/{link_id}/` if present.
pub fn run(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, link_id: []const u8) !void {
    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    const link_types = try reg.linkTypeSlice(allocator);
    defer allocator.free(link_types);

    const parsed = instance_id.parseLinkName(link_id, link_types) orelse return error.InvalidLinkName;

    const next_lt = reg.nextForLinkType(parsed.link_type) orelse return error.UnknownLinkType;
    if (parsed.n == 0 or parsed.n >= next_lt) return error.NotInIssuedRange;
    if (reg.isLinkTombstoned(parsed.link_type, parsed.n)) return error.AlreadyTombstoned;

    var link_report = links_validate.ValidationReport{ .allocator = allocator };
    defer link_report.deinit();

    var loaded = links_index.loadLinks(allocator, io, repo_root, &reg, &link_report) catch |err| switch (err) {
        error.LinksInvalid => {
            const lp = try links_index.formatLinksRelPath(allocator, repo_root);
            defer allocator.free(lp);
            link_report.print(lp);
            return err;
        },
        else => |e| return e,
    };
    defer loaded.deinit();

    var kept: std.ArrayList(links_index.LinkRowJson) = .empty;
    defer kept.deinit(allocator);

    var found = false;
    for (loaded.rows()) |r| {
        if (std.mem.eql(u8, r.id, link_id)) {
            found = true;
            continue;
        }
        try kept.append(allocator, r);
    }

    if (!found) return error.NothingToRemove;

    try links_index.writeLinksAtomic(io, allocator, repo_root, kept.items);

    try reg.tombstoneLinkNumeric(parsed.link_type, parsed.n, .{});
    try reg.save(io, repo_root);
    try tombstone_cache.syncFromRegistry(allocator, io, repo_root, &reg);

    const cwd = std.Io.Dir.cwd();
    const payload_dir = try std.fs.path.join(allocator, &.{ repo_root, links_index.relations_dir_name, link_id });
    defer allocator.free(payload_dir);
    try cwd.deleteTree(io, payload_dir);

    if (!builtin.is_test) std.debug.print("Removed link {s}\n", .{link_id});
}
