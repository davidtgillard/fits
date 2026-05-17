//! CLI use-case: append one validated link row to `links/links.jsonc` and advance the link-type counter in `.fits/registry.json`.
//! Endpoint ids must match the registered `in_type` and `out_type` for the given link type (`OUT` → `IN` in storage).

const builtin = @import("builtin");
const std = @import("std");
const fits_config = @import("../adapters/fs/fits_config.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const instance_id = @import("../domain/instance_id.zig");
const node_type = @import("../domain/node_type.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const links_validate = @import("../adapters/fs/links_validate.zig");
const path_layout = @import("../adapters/fs/path_layout.zig");

/// Default repository root when the CLI is run from the project tree.
pub const default_repo_root: []const u8 = ".";

fn assertIssuedAliveNode(reg: *const fits_registry.Registry, parsed: instance_id.ParsedNodeName) !void {
    const prefix = parsed.node_prefix;
    const n = parsed.n;
    const next_val = reg.nextForIdPrefix(prefix) orelse return error.UnknownIdPrefix;
    if (n == 0 or n >= next_val) return error.NotInIssuedRange;
    if (reg.isTombstoned(prefix, n)) return error.AlreadyTombstoned;
}

/// Appends a single link `{out}` → `{in}` of `link_type` using the next issued link id (`{LINK_TYPE}-{n}`).
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    link_type: []const u8,
    in_id: []const u8,
    out_id: []const u8,
) !void {
    try fits_registry.validateTypeName(link_type);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    if (!reg.hasLinkType(link_type)) return error.UnknownLinkType;

    const expected_in = reg.linkTypeInType(link_type) orelse return error.UnknownLinkType;
    const expected_out = reg.linkTypeOutType(link_type) orelse return error.UnknownLinkType;

    const id_prefixes = try reg.idPrefixSlice(allocator);
    defer allocator.free(id_prefixes);

    const pin = instance_id.parseNodeName(in_id, id_prefixes) orelse return error.InvalidObjName;
    const pout = instance_id.parseNodeName(out_id, id_prefixes) orelse return error.InvalidObjName;

    if (!node_type.endpointMatchesType(&reg, pin.node_prefix, expected_in) or
        !node_type.endpointMatchesType(&reg, pout.node_prefix, expected_out))
    {
        return error.LinkEndpointsMismatchRegistry;
    }

    try assertIssuedAliveNode(&reg, pin);
    try assertIssuedAliveNode(&reg, pout);

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

    const n_link = try reg.allocateNextLinkNumeric(link_type);

    const canon_in = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ pin.node_prefix, pin.n });
    defer allocator.free(canon_in);
    const canon_out = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ pout.node_prefix, pout.n });
    defer allocator.free(canon_out);

    {
        const new_id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ link_type, n_link });
        defer allocator.free(new_id);
        const lt_copy = try allocator.dupe(u8, link_type);
        defer allocator.free(lt_copy);
        const out_copy = try allocator.dupe(u8, canon_out);
        defer allocator.free(out_copy);
        const in_copy = try allocator.dupe(u8, canon_in);
        defer allocator.free(in_copy);

        const new_row = links_index.LinkRowJson{
            .id = new_id,
            .link_type = lt_copy,
            .out = out_copy,
            .in = in_copy,
            .labels = null,
        };

        var combined: std.ArrayList(links_index.LinkRowJson) = .empty;
        defer combined.deinit(allocator);

        for (loaded.rows()) |r| {
            try combined.append(allocator, r);
        }
        try combined.append(allocator, new_row);

        try links_index.writeLinksAtomic(io, allocator, repo_root, combined.items);
        try reg.save(io, repo_root);

        var prefs = try fits_config.loadParsedConfigForRepo(allocator, io, repo_root);
        defer prefs.deinit();
        if (prefs.linkCreateFolder(link_type)) |want| {
            if (want) {
                const cwd = std.Io.Dir.cwd();
                const rel_dir_rel = try path_layout.linkInstanceDir(allocator, link_type, new_id);
                defer allocator.free(rel_dir_rel);
                const rel_dir = try std.fs.path.join(allocator, &.{ repo_root, rel_dir_rel });
                defer allocator.free(rel_dir);
                try cwd.createDirPath(io, rel_dir);
            }
        }

        if (!builtin.is_test) {
            std.debug.print("Created link {s} ({s} -> {s})\n", .{ new_id, canon_out, canon_in });
        }
    }
}
