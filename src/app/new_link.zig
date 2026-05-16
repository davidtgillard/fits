//! CLI use-case: append one validated link row to `relations/links.jsonc` and advance the link-type counter in `.fits/registry.json`.
//! Endpoint ids must match the registered `in_obj_prefix` and `out_obj_prefix` for the given link type (`OUT` → `IN` in storage).

const builtin = @import("builtin");
const std = @import("std");
const fits_config = @import("../adapters/fs/fits_config.zig");
const fits_registry = @import("../adapters/fs/fits_registry.zig");
const instance_id = @import("../domain/instance_id.zig");
const links_index = @import("../adapters/fs/links_index.zig");
const links_validate = @import("../adapters/fs/links_validate.zig");

/// Default repository root when the CLI is run from the project tree.
pub const default_repo_root: []const u8 = ".";

/// Ensures `parsed` refers to a suffix already issued for its prefix and not tombstoned (mirrors link row validation for node endpoints).
fn assertIssuedAliveNode(reg: *const fits_registry.Registry, parsed: instance_id.ParsedNodeName) !void {
    const prefix = parsed.node_prefix;
    const n = parsed.n;
    const next_val = reg.nextForObjPrefix(prefix) orelse return error.UnknownObjPrefix;
    if (n == 0 or n >= next_val) return error.NotInIssuedRange;
    if (reg.isTombstoned(prefix, n)) return error.AlreadyTombstoned;
}

/// Appends a single link `{out}` → `{in}` of `link_type` using the next issued link id (`{LINK_TYPE}-{n}`).
///
/// Loads and semantically validates the existing links document first; allocates the link numeric on the in-memory registry,
/// writes `relations/links.jsonc`, then saves the registry (so a failed links write leaves the on-disk registry counter unchanged).
///
/// Parameters:
/// - `allocator`: Duplicates strings for the new row and transient buffers.
/// - `io`: Filesystem I/O.
/// - `repo_root`: Repository root containing `.fits/registry.json` and `relations/`.
/// - `link_type`: Registered link type name (`validateObjPrefix` + `hasLinkType`).
/// - `in_id`: Canonical **node** id for the **in** endpoint (registry `in_obj_prefix`), e.g. matching the first node type in `fits register link-type`.
/// - `out_id`: Canonical **node** id for the **out** endpoint (registry `out_obj_prefix`).
///
/// Returns: nothing on success.
/// On failure: prefix / parse / range / tombstone errors, [`error.UnknownLinkType`], [`error.LinkEndpointsMismatchRegistry`], links load/validation, or I/O.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    link_type: []const u8,
    in_id: []const u8,
    out_id: []const u8,
) !void {
    try fits_registry.validateObjPrefix(link_type);

    var reg = try fits_registry.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();

    if (!reg.hasLinkType(link_type)) return error.UnknownLinkType;

    const expected_in = reg.linkTypeInPrefix(link_type) orelse return error.UnknownLinkType;
    const expected_out = reg.linkTypeOutPrefix(link_type) orelse return error.UnknownLinkType;

    const obj_prefixes = try reg.objPrefixSlice(allocator);
    defer allocator.free(obj_prefixes);

    const pin = instance_id.parseNodeName(in_id, obj_prefixes) orelse return error.InvalidObjName;
    const pout = instance_id.parseNodeName(out_id, obj_prefixes) orelse return error.InvalidObjName;

    if (!std.mem.eql(u8, pin.node_prefix, expected_in) or !std.mem.eql(u8, pout.node_prefix, expected_out)) {
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
                const rel_dir = try std.fs.path.join(allocator, &.{ repo_root, links_index.relations_dir_name, new_id });
                defer allocator.free(rel_dir);
                try cwd.createDirPath(io, rel_dir);
            }
        }

        if (!builtin.is_test) {
            std.debug.print("Created link {s} ({s} -> {s})\n", .{ new_id, canon_out, canon_in });
        }
    }
}
