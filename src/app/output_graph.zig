//! Load the repo graph snapshot and print hook-protocol `graph` JSON to stdout.

const std = @import("std");
const persona = @import("../cli/persona.zig");
const loader_mod = @import("../adapters/fs/loader.zig");
const ignore_mod = @import("../adapters/git/ignore.zig");
const fits_registry_mod = @import("../adapters/fs/fits_registry.zig");
const links_index_mod = @import("../adapters/fs/links_index.zig");
const links_validate_mod = @import("../adapters/fs/links_validate.zig");
const graph_mod = @import("../domain/graph.zig");
const graph_builder_mod = @import("../domain/graph_builder.zig");
const graph_json = @import("../adapters/hooks/graph_json.zig");
const new_node_mod = @import("new_node.zig");
const registry_snapshot = @import("../adapters/fs/registry_snapshot.zig");

const ResolvedPersona = persona.ResolvedPersona;
const Io = std.Io;

/// Options for [`run`].
pub const Options = struct {
    /// Indent JSON with two spaces when true.
    pretty_print: bool = false,
};

/// Node bundles, links index, and graph snapshot loaded from disk.
/// Snapshot node ids alias `bundles`; edge `link_type` and endpoint ids alias `links`.
pub const LoadedGraph = struct {
    /// Owned bundles; must outlive `snapshot`.
    bundles: []graph_mod.NodeBundle,
    /// Parsed `links/links.jsonc`; must outlive `snapshot` edges.
    links: links_index_mod.LoadedLinks,
    /// Graph view built from `bundles` and link rows.
    snapshot: graph_mod.GraphSnapshot,

    /// Frees `snapshot`, bundle file bytes, link index storage, and the `bundles` slice.
    pub fn deinit(self: *LoadedGraph, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        for (self.bundles) |*b| freeBundle(allocator, b);
        allocator.free(self.bundles);
        self.links.deinit();
    }
};

/// Loads the repo graph (same source as validate hooks).
///
/// Parameters:
/// - `resolved`: Active persona (fixed-registry guard).
/// - `allocator`: Allocator for loads and snapshot slices.
/// - `io`: Filesystem I/O handle.
/// - `repo_root`: Repository root.
///
/// Returns: owned [`LoadedGraph`]; caller must [`LoadedGraph.deinit`].
/// On failure: invalid links print report then `error.LinksInvalid`.
pub fn loadGraph(
    resolved: *const ResolvedPersona,
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
) !LoadedGraph {
    var reg = try fits_registry_mod.loadRegistry(allocator, io, repo_root);
    defer reg.deinit();
    try ensureFixedRegistry(resolved, allocator, io, &reg);

    var link_report = links_validate_mod.ValidationReport{ .allocator = allocator };
    defer link_report.deinit();

    var links = links_index_mod.loadLinks(allocator, io, repo_root, &reg, &link_report) catch |err| switch (err) {
        error.LinksInvalid => {
            const lp = try links_index_mod.formatLinksRelPath(allocator, repo_root);
            defer allocator.free(lp);
            link_report.print(lp);
            return err;
        },
        else => |e| return e,
    };

    var link_edges = try allocator.alloc(graph_mod.LinkEdgeInput, links.rows().len);
    defer allocator.free(link_edges);
    for (links.rows(), 0..) |r, i| {
        link_edges[i] = .{
            .link_type = r.link_type,
            .out_id = r.out,
            .in_id = r.in,
        };
    }

    const ignore = ignore_mod.IgnoreMatcher.init(repo_root);
    const loader = loader_mod.Loader.init(ignore);
    const id_prefixes = try reg.idPrefixSlice(allocator);
    defer allocator.free(id_prefixes);

    const bundles = try loader.loadNodeBundles(allocator, io, repo_root, new_node_mod.default_objects_dir, &reg, id_prefixes);

    var builder = graph_builder_mod.DeterministicGraphBuilder{};
    const snapshot = try builder.asInterface().build(allocator, bundles, link_edges);
    return .{
        .bundles = bundles,
        .links = links,
        .snapshot = snapshot,
    };
}

/// Loads the repo graph and writes hook-equivalent `graph` JSON to stdout.
///
/// Parameters:
/// - `resolved`: Active persona (fixed-registry guard).
/// - `allocator`: Allocator for loads and output buffer.
/// - `io`: Filesystem I/O handle.
/// - `repo_root`: Repository root (typically `.`).
/// - `options`: Output formatting.
///
/// Returns: void on success.
/// On failure: registry/links load errors propagate; invalid links print report then `error.LinksInvalid`.
pub fn run(
    resolved: *const ResolvedPersona,
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []const u8,
    options: Options,
) !void {
    var loaded = try loadGraph(resolved, allocator, io, repo_root);
    defer loaded.deinit(allocator);

    const json = try graph_json.graphSnapshotJson(allocator, &loaded.snapshot, .{
        .pretty_print = options.pretty_print,
    });
    defer allocator.free(json);

    const line = try std.mem.concat(allocator, u8, &.{ json, "\n" });
    defer allocator.free(line);
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

/// Frees bundle file paths and contents allocated during load.
pub fn freeBundle(allocator: std.mem.Allocator, bundle: *graph_mod.NodeBundle) void {
    for (bundle.files) |f| {
        allocator.free(f.relative_path);
        allocator.free(f.contents);
    }
    allocator.free(bundle.files);
    allocator.free(bundle.id);
}

fn ensureFixedRegistry(resolved: *const ResolvedPersona, allocator: std.mem.Allocator, io: Io, reg: *const fits_registry_mod.Registry) !void {
    if (!resolved.fixedRegistry()) return;
    const m = resolved.manifest.?;
    try registry_snapshot.verifyRegistryForPersona(allocator, io, resolved.package_root, m.snapshot_rel, reg);
}
