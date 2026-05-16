//! fits CLI: dispatches subcommands and wires adapters to validate and graph-object lifecycle flows (nodes and links).

const builtin = @import("builtin");
const std = @import("std");
const loader_mod = @import("adapters/fs/loader.zig");
const ignore_mod = @import("adapters/git/ignore.zig");
const cache_mod = @import("adapters/cache/latticedb_cache.zig");
const fits_registry_mod = @import("adapters/fs/fits_registry.zig");
const links_index_mod = @import("adapters/fs/links_index.zig");
const links_validate_mod = @import("adapters/fs/links_validate.zig");
const graph_mod = @import("domain/graph.zig");
const graph_builder_mod = @import("domain/graph_builder.zig");
const validation = @import("domain/validation.zig");
const use_case_mod = @import("app/validate_use_case.zig");
const report_mod = @import("output/report.zig");
const new_link_mod = @import("app/new_link.zig");
const new_node_mod = @import("app/new_node.zig");
const register_mod = @import("app/register.zig");
const remove_object_mod = @import("app/remove_object.zig");
const update_mod = @import("app/update.zig");
const graph_link_endpoints_mod = @import("app/graph_link_endpoints_validator.zig");
const hooks_validate_mod = @import("app/hooks_validate.zig");
const hooks_config_mod = @import("adapters/fs/hooks_config.zig");
const init_repo_mod = @import("app/init_repo.zig");

/// Program entry: parses argv, runs a subcommand, prints usage on unknown input.
///
/// Parameters:
/// - `init`: Process bootstrap (allocator, args, I/O, etc.) from the Zig runtime.
///
/// Returns: nothing on success. On failure: argument parsing errors (including [`error.InvalidArgv`]),
/// validate pipeline errors, render errors, or registry / filesystem errors from other commands.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip executable name (argv[0]).
    const cmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "version")) {
        update_mod.runVersion();
        return;
    }

    if (std.mem.eql(u8, cmd, "update")) {
        try runUpdate(allocator, io, init.environ_map, &args);
        return;
    }

    if (!builtin.is_test and !std.mem.eql(u8, cmd, "update")) {
        if (update_mod.shouldSpawnBackgroundCheck(allocator, io, init.environ_map) catch false) {
            update_mod.spawnBackgroundCheck(allocator, io, init.environ_map) catch {};
        }
    }

    if (std.mem.eql(u8, cmd, "validate")) {
        try runValidate(allocator, io, init.environ_map, &args);
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        if (args.next() != null) {
            printUsage();
            return error.InvalidArgv;
        }
        try init_repo_mod.run(allocator, io, init_repo_mod.default_repo_root);
        return;
    }

    if (std.mem.eql(u8, cmd, "new")) {
        try runNew(allocator, io, &args);
        return;
    }

    if (std.mem.eql(u8, cmd, "register")) {
        try runRegister(allocator, io, &args);
        return;
    }

    if (std.mem.eql(u8, cmd, "rm")) {
        try runRm(allocator, io, &args);
        return;
    }

    printUsage();
}

// Loads bundles, runs validate use-case, optional JSON hooks, prints a text summary line.
fn runValidate(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: anytype) !void {
    var cli_hooks = false;
    var hooks_full = false;
    var hooks_incremental = true;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--hooks")) {
            cli_hooks = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--hooks-full")) {
            hooks_full = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-hooks-incremental")) {
            hooks_incremental = false;
            continue;
        }
        std.debug.print("unknown validate flag: {s}\n", .{a});
        return error.InvalidArgv;
    }

    var reg = try fits_registry_mod.loadRegistry(allocator, io, ".");
    defer reg.deinit();

    var link_report = links_validate_mod.ValidationReport{ .allocator = allocator };
    defer link_report.deinit();

    var loaded = links_index_mod.loadLinks(allocator, io, ".", &reg, &link_report) catch |err| switch (err) {
        error.LinksInvalid => {
            const lp = try links_index_mod.formatLinksRelPath(allocator, ".");
            defer allocator.free(lp);
            link_report.print(lp);
            return err;
        },
        else => |e| return e,
    };
    defer loaded.deinit();

    var link_edges = try allocator.alloc(graph_mod.LinkEdgeInput, loaded.rows().len);
    defer allocator.free(link_edges);
    for (loaded.rows(), 0..) |r, i| {
        link_edges[i] = .{
            .link_type = r.link_type,
            .out_id = r.out,
            .in_id = r.in,
        };
    }

    const ignore = ignore_mod.IgnoreMatcher.init(".");
    const loader = loader_mod.Loader.init(ignore);
    const prefixes = try reg.objPrefixSlice(allocator);
    defer allocator.free(prefixes);

    const bundles = try loader.loadNodeBundles(allocator, io, ".", "objects", prefixes);
    defer allocator.free(bundles);

    var hook_snapshot_builder = graph_builder_mod.DeterministicGraphBuilder{};
    const hook_snapshot = try hook_snapshot_builder.asInterface().build(allocator, bundles, link_edges);
    defer hook_snapshot.deinit(allocator);

    const store_dir = try cache_mod.LatticeDbCache.resolveStoreDir(allocator, io, environ, ".");
    defer allocator.free(store_dir);
    var cache = try cache_mod.LatticeDbCache.open(allocator, io, store_dir);
    defer cache.deinit();

    var deterministic_builder = graph_builder_mod.DeterministicGraphBuilder{};
    var built_in = BuiltInValidator{};
    var link_endpoints = graph_link_endpoints_mod.GraphLinkEndpointsValidator{};

    const validators = [_]validation.Validator{
        built_in.asInterface(),
        link_endpoints.asInterface(),
    };
    var registry = use_case_mod.StaticValidatorRegistry{
        .validators = validators[0..],
    };

    const use_case = use_case_mod.ValidateUseCase{
        .allocator = allocator,
        .graph_builder = deterministic_builder.asInterface(),
        .validator_registry = registry.asInterface(),
        .cache_store = cache.asInterface(),
    };

    const report = try use_case.execute(bundles, link_edges);

    var hook_cfg = try hooks_config_mod.load(allocator, io, ".");
    defer hook_cfg.deinit(allocator);

    const run_id = try makeValidateRunId(allocator);
    defer allocator.free(run_id);

    const git_head_opt = tryGitHead(allocator, io, ".");
    defer if (git_head_opt) |h| allocator.free(h);

    const hook_findings = try hooks_validate_mod.runHooks(
        allocator,
        io,
        ".",
        &reg,
        &loaded,
        bundles,
        &hook_snapshot,
        &cache,
        &hook_cfg,
        cli_hooks,
        hooks_full,
        hooks_incremental,
        run_id,
        git_head_opt,
    );

    const merged = try allocator.alloc(validation.Finding, report.findings.len + hook_findings.len);
    @memcpy(merged[0..report.findings.len], report.findings);
    @memcpy(merged[report.findings.len..], hook_findings);
    allocator.free(report.findings);
    allocator.free(hook_findings);

    const final_report = report_mod.Report{
        .findings = merged,
        .summary = report_mod.summarize(merged),
    };
    defer {
        for (merged) |f| allocator.free(f.message);
        allocator.free(merged);
    }

    var renderer = report_mod.TextRenderer{};
    try renderer.asInterface().render(final_report);
}

/// Best-effort `git rev-parse HEAD` for hook request metadata; returns null when git is missing or fails.
fn tryGitHead(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo_root, "rev-parse", "HEAD" },
        .cwd = .inherit,
    }) catch return null;
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const copy = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return copy;
}

/// Allocates an opaque run id (POSIX `CLOCK_REALTIME` on Linux when available).
fn makeValidateRunId(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.target.os.tag == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = undefined;
        if (linux.clock_gettime(.REALTIME, &ts) == 0) {
            return try std.fmt.allocPrint(allocator, "validate-{d}-{d}", .{ ts.sec, ts.nsec });
        }
    }
    return try allocator.dupe(u8, "validate");
}

fn runUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: anytype,
) !void {
    var check_only = false;
    var background = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--background")) {
            background = true;
            continue;
        }
        printUpdateUsage();
        return error.InvalidArgv;
    }

    var github_source: update_mod.GithubDevSource = .{ .environ = environ };
    const source = github_source.asInterface();

    if (background) {
        try update_mod.runBackgroundCheck(allocator, io, environ, source);
        return;
    }

    const store_dir = try cache_mod.LatticeDbCache.resolveStoreDir(allocator, io, environ, ".");
    defer allocator.free(store_dir);
    var cache = try cache_mod.LatticeDbCache.open(allocator, io, store_dir);
    defer cache.deinit();

    if (check_only) {
        update_mod.runCheck(allocator, io, source, &cache, .{}) catch |err| switch (err) {
            error.UpdateAvailable => return error.UpdateAvailable,
            else => return err,
        };
        return;
    }

    try update_mod.runApply(allocator, io, source, &cache);
}

// Prints supported commands to stderr via the debug print path.
fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  fits init
        \\  fits validate [--hooks] [--hooks-full] [--no-hooks-incremental]
        \\  fits new <OBJ_PREFIX> [--markdown] [-- <TITLE WORDS...>]
        \\  fits new link <LINK_TYPE> <IN_ID> <OUT_ID>
        \\  fits register obj-type <OBJ_PREFIX> [--create-folder]
        \\  fits register link-type <LINK_TYPE> <IN_OBJ_TYPE> <OUT_OBJ_TYPE> [--create-folder]
        \\  fits register list [obj-types|link-types]
        \\  fits register rename-type <OLD> <NEW>
        \\  fits register new <OBJ_PREFIX>   (deprecated)
        \\  fits register rename <OLD> <NEW>   (deprecated)
        \\  fits rm <OBJ_ID or LINK_ID>
        \\  fits update [--check]
        \\  fits version
        \\
    , .{});
}

fn printUpdateUsage() void {
    std.debug.print(
        \\Usage:
        \\  fits update [--check]
        \\
    , .{});
}

// Parses `fits rm` argv and delegates to [`remove_object_mod.run`].
fn runRm(allocator: std.mem.Allocator, io: std.Io, args: anytype) !void {
    const obj_name = args.next() orelse {
        printUsage();
        return error.InvalidArgv;
    };
    if (args.next() != null) {
        printUsage();
        return error.InvalidArgv;
    }
    try remove_object_mod.run(allocator, io, remove_object_mod.default_repo_root, remove_object_mod.default_objects_dir, obj_name);
}

fn printRegisterUsage() void {
    std.debug.print(
        \\Usage:
        \\  fits register obj-type <OBJ_PREFIX> [--create-folder]
        \\  fits register link-type <LINK_TYPE> <IN_OBJ_TYPE> <OUT_OBJ_TYPE> [--create-folder]
        \\  fits register list [obj-types|link-types]
        \\  fits register rename-type <OLD> <NEW>
        \\  fits register new <OBJ_PREFIX>   (deprecated)
        \\  fits register rename <OLD> <NEW>   (deprecated)
        \\
    , .{});
}

// Parses `fits new` argv and delegates to [`new_node_mod.run`] or [`new_link_mod.run`].
fn runNew(allocator: std.mem.Allocator, io: std.Io, args: anytype) !void {
    const first = args.next() orelse {
        printUsage();
        return error.InvalidArgv;
    };

    if (std.mem.eql(u8, first, "link")) {
        const link_type = args.next() orelse {
            printUsage();
            return error.InvalidArgv;
        };
        const in_id = args.next() orelse {
            printUsage();
            return error.InvalidArgv;
        };
        const out_id = args.next() orelse {
            printUsage();
            return error.InvalidArgv;
        };
        if (args.next() != null) {
            printUsage();
            return error.InvalidArgv;
        }
        try new_link_mod.run(allocator, io, new_link_mod.default_repo_root, link_type, in_id, out_id);
        return;
    }

    const obj_prefix = first;

    var markdown = false;
    var title_words: std.ArrayList([]const u8) = .empty;
    defer title_words.deinit(allocator);

    const Phase = enum { flags, title };
    var phase: Phase = .flags;

    while (args.next()) |arg| {
        switch (phase) {
            .flags => {
                if (std.mem.eql(u8, arg, "--markdown")) {
                    markdown = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--")) {
                    phase = .title;
                    continue;
                }
                std.debug.print("unexpected argument: {s}\n", .{arg});
                printUsage();
                return error.InvalidArgv;
            },
            .title => try title_words.append(allocator, arg),
        }
    }

    try new_node_mod.run(allocator, io, new_node_mod.default_repo_root, new_node_mod.default_objects_dir, obj_prefix, .{
        .markdown = markdown,
        .title_words = title_words.items,
    });
}

// Parses `fits register` argv and delegates to [`register_mod`].
fn runRegister(allocator: std.mem.Allocator, io: std.Io, args: anytype) !void {
    const sub = args.next() orelse {
        printRegisterUsage();
        return error.InvalidArgv;
    };

    if (std.mem.eql(u8, sub, "new")) {
        const obj_prefix = args.next() orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        if (args.next() != null) {
            printRegisterUsage();
            return error.InvalidArgv;
        }
        try register_mod.runNew(allocator, io, register_mod.default_repo_root, obj_prefix);
        return;
    }

    if (std.mem.eql(u8, sub, "obj-type")) {
        var create_folder = false;
        var prefix: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--create-folder")) {
                create_folder = true;
                continue;
            }
            if (prefix != null) {
                printRegisterUsage();
                return error.InvalidArgv;
            }
            prefix = arg;
        }
        const p = prefix orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        try register_mod.runObjType(allocator, io, register_mod.default_repo_root, p, create_folder);
        return;
    }

    if (std.mem.eql(u8, sub, "link-type")) {
        var create_folder = false;
        var link_type: ?[]const u8 = null;
        var in_prefix: ?[]const u8 = null;
        var out_prefix: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--create-folder")) {
                create_folder = true;
                continue;
            }
            if (link_type == null) {
                link_type = arg;
            } else if (in_prefix == null) {
                in_prefix = arg;
            } else if (out_prefix == null) {
                out_prefix = arg;
            } else {
                printRegisterUsage();
                return error.InvalidArgv;
            }
        }
        const lt = link_type orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        const ip = in_prefix orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        const op = out_prefix orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        try register_mod.runLinkType(allocator, io, register_mod.default_repo_root, lt, ip, op, create_folder);
        return;
    }

    if (std.mem.eql(u8, sub, "list")) {
        const filter = args.next();
        if (filter == null) {
            try register_mod.runListAll(allocator, io, register_mod.default_repo_root);
            return;
        }
        if (args.next() != null) {
            printRegisterUsage();
            return error.InvalidArgv;
        }
        if (std.mem.eql(u8, filter.?, "obj-types")) {
            try register_mod.runListObjTypes(allocator, io, register_mod.default_repo_root);
            return;
        }
        if (std.mem.eql(u8, filter.?, "link-types")) {
            try register_mod.runListLinkTypes(allocator, io, register_mod.default_repo_root);
            return;
        }
        printRegisterUsage();
        return error.InvalidArgv;
    }

    if (std.mem.eql(u8, sub, "rename-type")) {
        const old_name = args.next() orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        const new_name = args.next() orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        if (args.next() != null) {
            printRegisterUsage();
            return error.InvalidArgv;
        }
        try register_mod.runRenameType(allocator, io, register_mod.default_repo_root, register_mod.default_objects_dir, old_name, new_name);
        return;
    }

    if (std.mem.eql(u8, sub, "rename")) {
        const old_prefix = args.next() orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        const new_prefix = args.next() orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        if (args.next() != null) {
            printRegisterUsage();
            return error.InvalidArgv;
        }
        try register_mod.runRename(allocator, io, register_mod.default_repo_root, register_mod.default_objects_dir, old_prefix, new_prefix);
        return;
    }

    printRegisterUsage();
    return error.InvalidArgv;
}

/// Placeholder in-process validator (no-op findings) until real checks exist.
const BuiltInValidator = struct {
    /// Exposes this value as a [`validation.Validator`].
    ///
    /// Parameters:
    /// - `self`: Must outlive any `validate`/`name` calls on the returned validator.
    ///
    /// Returns: a [`validation.Validator`] vtable backed by this struct.
    pub fn asInterface(self: *BuiltInValidator) validation.Validator {
        return .{
            .context = self,
            .vtable = &.{
                .name = nameAdapter,
                .validate = validateAdapter,
            },
        };
    }

    // Vtable: fixed name for the built-in stub.
    fn nameAdapter(context: *anyopaque) []const u8 {
        const self: *BuiltInValidator = @ptrCast(@alignCast(context));
        _ = self;
        return "builtin.placeholder";
    }

    // Vtable: returns an empty owned finding list.
    fn validateAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        input: validation.ValidationInput,
    ) anyerror!validation.ValidationResult {
        const self: *BuiltInValidator = @ptrCast(@alignCast(context));
        _ = self;
        _ = input;

        const findings = try allocator.alloc(validation.Finding, 0);
        return .{
            .validator_name = "builtin.placeholder",
            .findings = findings,
        };
    }
};

test {
    _ = @import("adapters/fs/fits_registry.zig");
    _ = @import("adapters/fs/registry_validate.zig");
    _ = @import("adapters/fs/fits_config.zig");
    _ = @import("adapters/cache/latticedb_cache.zig");
    _ = @import("adapters/github/release.zig");
    _ = @import("app/update.zig");
    _ = @import("app/new_link.zig");
    _ = @import("app/new_node.zig");
    _ = @import("app/register.zig");
    _ = @import("app/init_repo.zig");
    _ = @import("test/fits_registry_functional.zig");
    _ = @import("test/new_link_functional.zig");
    _ = @import("test/new_node_functional.zig");
    _ = @import("test/register_functional.zig");
    _ = @import("test/links_functional.zig");
    _ = @import("test/remove_object_functional.zig");
    _ = @import("test/update_functional.zig");
    _ = @import("test/init_functional.zig");
    _ = @import("adapters/git/removal.zig");
    _ = @import("domain/instance_id.zig");
    _ = @import("domain/graph_subgraph.zig");
    _ = @import("domain/hook_protocol.zig");
    _ = @import("adapters/hooks/git_dirty.zig");
    _ = @import("adapters/hooks/hook_request.zig");
    _ = @import("app/hooks_validate.zig");
}
