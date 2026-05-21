//! [`FitsRepo`]: repository session and engine operations (Zig API).

const std = @import("std");
const loader_mod = @import("../adapters/fs/loader.zig");
const ignore_mod = @import("../adapters/git/ignore.zig");
const cache_mod = @import("../adapters/cache/fits_cache.zig");
const fits_registry_mod = @import("../adapters/fs/fits_registry.zig");
const links_index_mod = @import("../adapters/fs/links_index.zig");
const links_validate_mod = @import("../adapters/fs/links_validate.zig");
const graph_mod = @import("../domain/graph.zig");
const graph_builder_mod = @import("../domain/graph_builder.zig");
const validation = @import("../domain/validation.zig");
const use_case_mod = @import("../app/validate_use_case.zig");
const report_mod = @import("../output/report.zig");
const new_link_mod = @import("../app/new_link.zig");
const new_node_mod = @import("../app/new_node.zig");
const register_mod = @import("../app/register.zig");
const remove_object_mod = @import("../app/remove_object.zig");
const init_repo_mod = @import("../app/init_repo.zig");
const graph_link_endpoints_mod = @import("../app/graph_link_endpoints_validator.zig");
const registry_snapshot = @import("../adapters/fs/registry_snapshot.zig");
const graph_json = @import("../adapters/hooks/graph_json.zig");
const output_graph_mod = @import("../app/output_graph.zig");

const Io = std.Io;

/// Options for [`FitsRepo.validate`].
pub const ValidateOptions = struct {
    include_link_endpoints: bool = true,
};

/// Open-session configuration.
pub const OpenOptions = struct {
    repo_root: []const u8 = ".",
    registry_snapshot_path: ?[]const u8 = null,
};

/// Repository session: root path, optional fixed registry snapshot, and I/O.
pub const FitsRepo = struct {
    allocator: std.mem.Allocator,
    io: Io,
    repo_root: []u8,
    registry_snapshot_path: ?[]u8,

    /// Opens a repo session; duplicates paths into `allocator`.
    pub fn open(allocator: std.mem.Allocator, io: Io, options: OpenOptions) !*FitsRepo {
        const self = try allocator.create(FitsRepo);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .repo_root = try allocator.dupe(u8, options.repo_root),
            .registry_snapshot_path = if (options.registry_snapshot_path) |p|
                try allocator.dupe(u8, p)
            else
                null,
        };
        return self;
    }

    /// Releases session-owned strings and the session allocation.
    pub fn close(self: *FitsRepo) void {
        self.allocator.free(self.repo_root);
        if (self.registry_snapshot_path) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }

    fn ensureSnapshot(self: *const FitsRepo, reg: *const fits_registry_mod.Registry) !void {
        const snap = self.registry_snapshot_path orelse return;
        try registry_snapshot.verifyRegistryAtSnapshot(self.allocator, self.io, snap, reg);
    }

    fn ensureNodePrefixAllowed(self: *const FitsRepo, id_prefix: []const u8) !void {
        const snap = self.registry_snapshot_path orelse return;
        if (!try registry_snapshot.snapshotHasIdPrefix(self.allocator, self.io, snap, id_prefix)) {
            return error.UnknownIdPrefix;
        }
    }

    /// Verifies the live registry against the configured snapshot file.
    pub fn verifyRegistrySnapshot(self: *const FitsRepo) !void {
        var reg = try fits_registry_mod.loadRegistry(self.allocator, self.io, self.repo_root);
        defer reg.deinit();
        try self.ensureSnapshot(&reg);
    }

    /// Initializes a new fits repository at `repo_root`.
    pub fn initRepo(self: *const FitsRepo, options: init_repo_mod.InitOptions) !void {
        try init_repo_mod.run(self.allocator, self.io, self.repo_root, options);
    }

    /// Registers a node type.
    pub fn registerNodeType(self: *const FitsRepo, type_name: []const u8, opts: register_mod.NodeTypeOpts) !void {
        try register_mod.runNodeType(self.allocator, self.io, self.repo_root, type_name, opts);
    }

    /// Registers a link type.
    pub fn registerLinkType(
        self: *const FitsRepo,
        link_type: []const u8,
        in_type: []const u8,
        out_type: []const u8,
        create_folder: bool,
    ) !void {
        try register_mod.runLinkType(self.allocator, self.io, self.repo_root, link_type, in_type, out_type, create_folder);
    }

    /// Creates a new node; returns the display id (caller frees).
    pub fn newNode(self: *const FitsRepo, id_prefix: []const u8, options: new_node_mod.NewOptions) ![]const u8 {
        try self.ensureNodePrefixAllowed(id_prefix);
        var reg = try fits_registry_mod.loadRegistry(self.allocator, self.io, self.repo_root);
        defer reg.deinit();
        try self.ensureSnapshot(&reg);
        return new_node_mod.runReturningId(
            self.allocator,
            self.io,
            self.repo_root,
            new_node_mod.default_objects_dir,
            id_prefix,
            options,
        );
    }

    /// Creates a new link.
    pub fn newLink(self: *const FitsRepo, link_type: []const u8, in_id: []const u8, out_id: []const u8) !void {
        var reg = try fits_registry_mod.loadRegistry(self.allocator, self.io, self.repo_root);
        defer reg.deinit();
        try self.ensureSnapshot(&reg);
        try new_link_mod.run(self.allocator, self.io, self.repo_root, link_type, in_id, out_id);
    }

    /// Removes a node or link by id.
    pub fn remove(self: *const FitsRepo, object_id: []const u8) !void {
        var reg = try fits_registry_mod.loadRegistry(self.allocator, self.io, self.repo_root);
        defer reg.deinit();
        try self.ensureSnapshot(&reg);
        try remove_object_mod.run(self.allocator, self.io, self.repo_root, remove_object_mod.default_objects_dir, object_id);
    }

    /// Structural validation (built-in + optional link endpoints); no subprocess hooks.
    pub fn validate(self: *const FitsRepo, options: ValidateOptions) !report_mod.Report {
        var reg = try fits_registry_mod.loadRegistry(self.allocator, self.io, self.repo_root);
        defer reg.deinit();
        try self.ensureSnapshot(&reg);

        var link_report = links_validate_mod.ValidationReport{ .allocator = self.allocator };
        defer link_report.deinit();

        var loaded = links_index_mod.loadLinks(self.allocator, self.io, self.repo_root, &reg, &link_report) catch |err| switch (err) {
            error.LinksInvalid => {
                const lp = try links_index_mod.formatLinksRelPath(self.allocator, self.repo_root);
                defer self.allocator.free(lp);
                link_report.print(lp);
                return err;
            },
            else => |e| return e,
        };
        defer loaded.deinit();

        var link_edges = try self.allocator.alloc(graph_mod.LinkEdgeInput, loaded.rows().len);
        defer self.allocator.free(link_edges);
        for (loaded.rows(), 0..) |r, i| {
            link_edges[i] = .{
                .link_type = r.link_type,
                .out_id = r.out,
                .in_id = r.in,
            };
        }

        const ignore = ignore_mod.IgnoreMatcher.init(self.repo_root);
        const loader = loader_mod.Loader.init(ignore);
        const id_prefixes = try reg.idPrefixSlice(self.allocator);
        defer self.allocator.free(id_prefixes);

        const bundles = try loader.loadNodeBundles(
            self.allocator,
            self.io,
            self.repo_root,
            new_node_mod.default_objects_dir,
            &reg,
            id_prefixes,
        );
        defer {
            for (bundles) |*b| output_graph_mod.freeBundle(self.allocator, b);
            self.allocator.free(bundles);
        }

        var built_in = BuiltInValidator{};
        var link_endpoints = graph_link_endpoints_mod.GraphLinkEndpointsValidator{};
        var validators_list: [2]validation.Validator = .{
            built_in.asInterface(),
            link_endpoints.asInterface(),
        };
        const validators_len: usize = if (options.include_link_endpoints) 2 else 1;

        var registry_val = use_case_mod.StaticValidatorRegistry{
            .validators = validators_list[0..validators_len],
        };

        var deterministic_builder = graph_builder_mod.DeterministicGraphBuilder{};
        const use_case = use_case_mod.ValidateUseCase{
            .allocator = self.allocator,
            .graph_builder = deterministic_builder.asInterface(),
            .validator_registry = registry_val.asInterface(),
            .cache_store = nullCacheStore(),
        };

        return use_case.execute(bundles, link_edges);
    }

    /// Returns hook-protocol graph JSON (caller frees).
    pub fn outputGraphJson(self: *const FitsRepo, pretty_print: bool) ![]const u8 {
        var reg = try fits_registry_mod.loadRegistry(self.allocator, self.io, self.repo_root);
        defer reg.deinit();
        try self.ensureSnapshot(&reg);

        var link_report = links_validate_mod.ValidationReport{ .allocator = self.allocator };
        defer link_report.deinit();

        var links = links_index_mod.loadLinks(self.allocator, self.io, self.repo_root, &reg, &link_report) catch |err| switch (err) {
            error.LinksInvalid => {
                const lp = try links_index_mod.formatLinksRelPath(self.allocator, self.repo_root);
                defer self.allocator.free(lp);
                link_report.print(lp);
                return err;
            },
            else => |e| return e,
        };
        defer links.deinit();

        var link_edges = try self.allocator.alloc(graph_mod.LinkEdgeInput, links.rows().len);
        defer self.allocator.free(link_edges);
        for (links.rows(), 0..) |r, i| {
            link_edges[i] = .{
                .link_type = r.link_type,
                .out_id = r.out,
                .in_id = r.in,
            };
        }

        const ignore = ignore_mod.IgnoreMatcher.init(self.repo_root);
        const loader = loader_mod.Loader.init(ignore);
        const id_prefixes = try reg.idPrefixSlice(self.allocator);
        defer self.allocator.free(id_prefixes);

        const bundles = try loader.loadNodeBundles(
            self.allocator,
            self.io,
            self.repo_root,
            new_node_mod.default_objects_dir,
            &reg,
            id_prefixes,
        );
        defer {
            for (bundles) |*b| output_graph_mod.freeBundle(self.allocator, b);
            self.allocator.free(bundles);
        }

        var builder = graph_builder_mod.DeterministicGraphBuilder{};
        const snapshot = try builder.asInterface().build(self.allocator, bundles, link_edges);
        defer snapshot.deinit(self.allocator);

        return graph_json.graphSnapshotJson(self.allocator, &snapshot, .{
            .pretty_print = pretty_print,
        });
    }
};

var null_cache_ctx: u8 = 0;

fn nullCachePut(context: *anyopaque, key: []const u8, value: []const u8) !void {
    _ = context;
    _ = key;
    _ = value;
}

fn nullCacheGet(context: *anyopaque, key: []const u8) !?[]const u8 {
    _ = context;
    _ = key;
    return null;
}

fn nullCacheStore() cache_mod.CacheStore {
    return .{
        .context = &null_cache_ctx,
        .vtable = &.{
            .put = nullCachePut,
            .get = nullCacheGet,
        },
    };
}

const BuiltInValidator = struct {
    pub fn asInterface(self: *BuiltInValidator) validation.Validator {
        return .{
            .context = self,
            .vtable = &.{
                .name = nameAdapter,
                .validate = validateAdapter,
            },
        };
    }

    fn nameAdapter(context: *anyopaque) []const u8 {
        _ = @as(*BuiltInValidator, @ptrCast(@alignCast(context)));
        return "builtin.placeholder";
    }

    fn validateAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        input: validation.ValidationInput,
    ) anyerror!validation.ValidationResult {
        _ = @as(*BuiltInValidator, @ptrCast(@alignCast(context)));
        _ = input;
        const issues = try allocator.alloc(validation.ValidationIssue, 0);
        return .{
            .validator_name = "builtin.placeholder",
            .issues = issues,
        };
    }
};
