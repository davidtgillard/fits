//! CLI host: dispatches subcommands for the default fits persona or a resolved named persona.

const builtin = @import("builtin");
const std = @import("std");
const persona = @import("persona.zig");
const persona_manifest = @import("persona_manifest.zig");
const extension_run = @import("extension_run.zig");
const loader_mod = @import("../adapters/fs/loader.zig");
const ignore_mod = @import("../adapters/git/ignore.zig");
const cache_mod = @import("../adapters/cache/latticedb_cache.zig");
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
const register_rm_mod = @import("../app/register_rm.zig");
const remove_object_mod = @import("../app/remove_object.zig");
const update_mod = @import("../app/update.zig");
const graph_link_endpoints_mod = @import("../app/graph_link_endpoints_validator.zig");
const hooks_validate_mod = @import("../app/hooks_validate.zig");
const hooks_config_mod = @import("../adapters/fs/hooks_config.zig");
const init_repo_mod = @import("../app/init_repo.zig");
const registry_snapshot = @import("../adapters/fs/registry_snapshot.zig");
const persona_install = @import("../adapters/fs/persona_install.zig");

const Command = persona.Command;
const ResolvedPersona = persona.ResolvedPersona;

/// Runs the CLI for `resolved` persona using remaining args in `args_iter`.
pub fn runCli(
    resolved: *const ResolvedPersona,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args_iter: anytype,
) !void {
    const cmd_str = args_iter.next() orelse {
        printUsage(resolved);
        return;
    };

    const cmd = parseCommand(cmd_str) orelse {
        if (!resolved.is_default) {
            if (resolved.manifest) |*m| {
                if (m.extensionByName(cmd_str)) |ext| {
                    return runExtension(resolved, allocator, io, environ, args_iter, ext);
                }
            }
        }
        printUsage(resolved);
        return;
    };

    if (!resolved.allows(cmd)) {
        std.debug.print("{s}: command '{s}' is not available for this persona\n", .{ resolved.id, cmd_str });
        return error.CommandNotAllowed;
    }

    switch (cmd) {
        .version => {
            runPersonaVersion(resolved);
            return;
        },
        .update => {
            try runUpdate(allocator, io, environ, args_iter);
            return;
        },
        .validate => {
            try runValidate(resolved, allocator, io, environ, args_iter);
            return;
        },
        .init => {
            if (args_iter.next() != null) {
                printUsage(resolved);
                return error.InvalidArgv;
            }
            try init_repo_mod.run(allocator, io, init_repo_mod.default_repo_root);
            return;
        },
        .new => {
            try runNew(resolved, allocator, io, args_iter);
            return;
        },
        .register => {
            try runRegister(allocator, io, args_iter);
            return;
        },
        .rm => {
            try runRm(resolved, allocator, io, args_iter);
            return;
        },
        .persona => {
            try runPersonaAdmin(allocator, io, environ, args_iter);
            return;
        },
    }
}

/// Whether to spawn fits background update check for this invocation.
pub fn shouldBackgroundUpdate(resolved: *const ResolvedPersona, cmd_str: []const u8) bool {
    if (!resolved.backgroundUpdateCheck()) return false;
    return !std.mem.eql(u8, cmd_str, "update");
}

fn parseCommand(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "init")) return .init;
    if (std.mem.eql(u8, name, "validate")) return .validate;
    if (std.mem.eql(u8, name, "new")) return .new;
    if (std.mem.eql(u8, name, "rm")) return .rm;
    if (std.mem.eql(u8, name, "register")) return .register;
    if (std.mem.eql(u8, name, "update")) return .update;
    if (std.mem.eql(u8, name, "version")) return .version;
    if (std.mem.eql(u8, name, "persona")) return .persona;
    return null;
}

fn runPersonaVersion(resolved: *const ResolvedPersona) void {
    if (resolved.is_default) {
        update_mod.runVersion();
        return;
    }
    if (resolved.manifest) |m| {
        std.debug.print("{s} {s}\n", .{ resolved.id, m.version });
    }
}

fn runExtension(
    resolved: *const ResolvedPersona,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args_iter: anytype,
    ext: *const persona_manifest.ExtensionDef,
) !void {
    const m = resolved.manifest.?;
    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    defer extra.deinit(allocator);
    while (args_iter.next()) |a| try extra.append(allocator, a);

    var argv_parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_parts.deinit(allocator);

    const pkg_argv = try extension_run.resolveHookArgv(allocator, io, resolved.package_root, ext.run_argv);
    defer {
        for (pkg_argv) |s| allocator.free(s);
        allocator.free(pkg_argv);
    }
    try argv_parts.appendSlice(allocator, pkg_argv);
    try argv_parts.appendSlice(allocator, extra.items);

    try extension_run.runExtensionArgv(
        allocator,
        io,
        environ,
        ".",
        resolved.id,
        m.version,
        argv_parts.items,
    );
}

fn ensureFixedRegistry(resolved: *const ResolvedPersona, allocator: std.mem.Allocator, io: std.Io, reg: *const fits_registry_mod.Registry) !void {
    if (!resolved.fixedRegistry()) return;
    const m = resolved.manifest.?;
    try registry_snapshot.verifyRegistryForPersona(allocator, io, resolved.package_root, m.snapshot_rel, reg);
}

fn ensureNodePrefixAllowed(resolved: *const ResolvedPersona, allocator: std.mem.Allocator, io: std.Io, node_prefix: []const u8) !void {
    if (!resolved.fixedRegistry()) return;
    const m = resolved.manifest.?;
    var schema = try registry_snapshot.loadTypeSchema(allocator, io, resolved.package_root, m.snapshot_rel);
    defer schema.deinit(allocator);
    if (!registry_snapshot.schemaHasIdPrefix(&schema, node_prefix)) {
        std.debug.print("id prefix '{s}' is not part of persona '{s}' schema\n", .{ node_prefix, resolved.id });
        return error.UnknownIdPrefix;
    }
}

fn runValidate(
    resolved: *const ResolvedPersona,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: anytype,
) !void {
    var hooks_full = false;
    var hooks_incremental = true;
    while (args.next()) |a| {
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
    try ensureFixedRegistry(resolved, allocator, io, &reg);

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
    const id_prefixes = try reg.idPrefixSlice(allocator);
    defer allocator.free(id_prefixes);

    const bundles = try loader.loadNodeBundles(allocator, io, ".", new_node_mod.default_objects_dir, &reg, id_prefixes);
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

    var validators_list: [2]validation.Validator = .{
        built_in.asInterface(),
        link_endpoints.asInterface(),
    };
    var validators_len: usize = 2;
    if (resolved.manifest) |m| {
        if (!m.validate_include_link_endpoints) validators_len = 1;
    }

    var registry_val = use_case_mod.StaticValidatorRegistry{
        .validators = validators_list[0..validators_len],
    };

    const use_case = use_case_mod.ValidateUseCase{
        .allocator = allocator,
        .graph_builder = deterministic_builder.asInterface(),
        .validator_registry = registry_val.asInterface(),
        .cache_store = cache.asInterface(),
    };

    const report = try use_case.execute(bundles, link_edges);

    var hook_cfg = hooks_config_mod.HooksConfig{};
    defer hook_cfg.deinit(allocator);

    if (resolved.manifest) |m| {
        if (m.primaryHook()) |hook_def| {
            hook_cfg.enabled = m.validate_hooks_default;
            hook_cfg.nodes_argv = try extension_run.resolveHookArgv(allocator, io, resolved.package_root, hook_def.nodes_argv);
            hook_cfg.links_argv = try extension_run.resolveHookArgv(allocator, io, resolved.package_root, hook_def.links_argv);
            hook_cfg.timeout_ns = hook_def.timeout_secs * std.time.ns_per_s;
        }
    } else {
        hook_cfg = try hooks_config_mod.load(allocator, io, ".");
    }

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
        std.debug.print("Usage:\n  fits update [--check]\n\n", .{});
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
            // Exit 1 without printing a second "error: …" line; message already shown.
            error.UpdateAvailable => std.process.exit(1),
            else => {
                if (update_mod.isReportedUpdateError(err)) std.process.exit(1);
                return err;
            },
        };
        return;
    }

    update_mod.runApply(allocator, io, source, &cache) catch |err| {
        if (update_mod.isReportedUpdateError(err)) std.process.exit(1);
        return err;
    };
}

fn runRm(resolved: *const ResolvedPersona, allocator: std.mem.Allocator, io: std.Io, args: anytype) !void {
    const id_arg = args.next() orelse {
        printUsage(resolved);
        return error.InvalidArgv;
    };
    if (args.next() != null) {
        printUsage(resolved);
        return error.InvalidArgv;
    }
    var reg = try fits_registry_mod.loadRegistry(allocator, io, ".");
    defer reg.deinit();
    try ensureFixedRegistry(resolved, allocator, io, &reg);
    try remove_object_mod.run(allocator, io, remove_object_mod.default_repo_root, remove_object_mod.default_objects_dir, id_arg);
}

fn runNew(resolved: *const ResolvedPersona, allocator: std.mem.Allocator, io: std.Io, args: anytype) !void {
    const first = args.next() orelse {
        printUsage(resolved);
        return error.InvalidArgv;
    };

    if (std.mem.eql(u8, first, "link")) {
        const link_type = args.next() orelse {
            printUsage(resolved);
            return error.InvalidArgv;
        };
        const in_id = args.next() orelse {
            printUsage(resolved);
            return error.InvalidArgv;
        };
        const out_id = args.next() orelse {
            printUsage(resolved);
            return error.InvalidArgv;
        };
        if (args.next() != null) {
            printUsage(resolved);
            return error.InvalidArgv;
        }
        var reg = try fits_registry_mod.loadRegistry(allocator, io, ".");
        defer reg.deinit();
        try ensureFixedRegistry(resolved, allocator, io, &reg);
        try new_link_mod.run(allocator, io, new_link_mod.default_repo_root, link_type, in_id, out_id);
        return;
    }

    if (!std.mem.eql(u8, first, "node")) {
        printUsage(resolved);
        return error.InvalidArgv;
    }

    const node_prefix = args.next() orelse {
        printUsage(resolved);
        return error.InvalidArgv;
    };
    try ensureNodePrefixAllowed(resolved, allocator, io, node_prefix);

    var reg = try fits_registry_mod.loadRegistry(allocator, io, ".");
    defer reg.deinit();
    try ensureFixedRegistry(resolved, allocator, io, &reg);

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
                printUsage(resolved);
                return error.InvalidArgv;
            },
            .title => try title_words.append(allocator, arg),
        }
    }

    try new_node_mod.run(allocator, io, new_node_mod.default_repo_root, new_node_mod.default_objects_dir, node_prefix, .{
        .markdown = markdown,
        .title_words = title_words.items,
    });
}

fn runRegister(allocator: std.mem.Allocator, io: std.Io, args: anytype) !void {
    const sub = args.next() orelse {
        printRegisterUsage();
        return error.InvalidArgv;
    };

    if (std.mem.eql(u8, sub, "new")) {
        const node_prefix = args.next() orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        if (args.next() != null) {
            printRegisterUsage();
            return error.InvalidArgv;
        }
        try register_mod.runNew(allocator, io, register_mod.default_repo_root, node_prefix);
        return;
    }

    if (std.mem.eql(u8, sub, "node-type") or std.mem.eql(u8, sub, "obj-type")) {
        if (std.mem.eql(u8, sub, "obj-type") and !builtin.is_test) {
            std.debug.print("warning: `fits register obj-type` is deprecated; use `fits register node-type`\n", .{});
        }
        var opts: register_mod.NodeTypeOpts = .{};
        var type_name: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--create-folder")) {
                opts.create_folder = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--abstract")) {
                opts.abstract = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--extends")) {
                opts.extends = args.next() orelse {
                    printRegisterUsage();
                    return error.InvalidArgv;
                };
                continue;
            }
            if (type_name != null) {
                printRegisterUsage();
                return error.InvalidArgv;
            }
            type_name = arg;
        }
        const tn = type_name orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        try register_mod.runNodeType(allocator, io, register_mod.default_repo_root, tn, opts);
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
        if (std.mem.eql(u8, filter.?, "node-types") or std.mem.eql(u8, filter.?, "obj-types")) {
            if (std.mem.eql(u8, filter.?, "obj-types") and !builtin.is_test) {
                std.debug.print("warning: `fits register list obj-types` is deprecated; use `fits register list node-types`\n", .{});
            }
            try register_mod.runListNodeTypes(allocator, io, register_mod.default_repo_root);
            return;
        }
        if (std.mem.eql(u8, filter.?, "link-types")) {
            try register_mod.runListLinkTypes(allocator, io, register_mod.default_repo_root);
            return;
        }
        printRegisterUsage();
        return error.InvalidArgv;
    }

    if (std.mem.eql(u8, sub, "rm")) {
        var force = false;
        var preserve_local = false;
        var cascade = false;
        var type_name: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--force")) {
                force = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--preserve-local")) {
                preserve_local = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--cascade")) {
                cascade = true;
                continue;
            }
            if (type_name != null) {
                printRegisterUsage();
                return error.InvalidArgv;
            }
            type_name = arg;
        }
        const tn = type_name orelse {
            printRegisterUsage();
            return error.InvalidArgv;
        };
        try register_rm_mod.runRemoveType(allocator, io, register_mod.default_repo_root, register_mod.default_objects_dir, tn, .{
            .force = force,
            .preserve_local = preserve_local,
            .cascade = cascade,
        });
        return;
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

fn runPersonaAdmin(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: anytype) !void {
    const sub = args.next() orelse {
        std.debug.print(
            \\Usage:
            \\  fits persona install <package-path> [--link]
            \\  fits persona list
            \\  fits persona info <id>
            \\
        , .{});
        return error.InvalidArgv;
    };
    if (std.mem.eql(u8, sub, "install")) {
        const path = args.next() orelse return error.InvalidArgv;
        var link = false;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--link")) link = true else return error.InvalidArgv;
        }
        _ = try persona_install.install(allocator, io, environ, path, link);
        return;
    }
    if (std.mem.eql(u8, sub, "list")) {
        const ids = try persona_install.listInstalled(allocator, io, environ);
        defer {
            for (ids) |s| allocator.free(s);
            allocator.free(ids);
        }
        for (ids) |id| std.debug.print("{s}\n", .{id});
        return;
    }
    if (std.mem.eql(u8, sub, "info")) {
        const id = args.next() orelse return error.InvalidArgv;
        if (args.next() != null) return error.InvalidArgv;
        try persona_install.printInfo(allocator, io, environ, id);
        return;
    }
    return error.InvalidArgv;
}

fn printUsage(resolved: *const ResolvedPersona) void {
    const name = resolved.id;
    if (resolved.is_default) {
        std.debug.print(
            \\Usage:
            \\  {s} init
            \\  {s} validate [--hooks-full] [--no-hooks-incremental]
            \\  {s} new node <NODE_PREFIX> [--markdown] [-- <TITLE WORDS...>]
            \\  {s} new link <LINK_TYPE> <IN_ID> <OUT_ID>
            \\  {s} register node-type <NODE_PREFIX> [--create-folder]
            \\  {s} register link-type <LINK_TYPE> <IN_NODE_TYPE> <OUT_NODE_TYPE> [--create-folder]
            \\  {s} register list [node-types|link-types]
            \\  {s} register rename-type <OLD> <NEW>
            \\  {s} register rm <TYPE> [--force] [--preserve-local] [--cascade]
            \\  {s} rm <NODE_ID or LINK_ID>
            \\  {s} persona install <path> [--link]
            \\  {s} persona list
            \\  {s} persona info <id>
            \\  {s} update [--check]
            \\  {s} version
            \\
        , .{ name, name, name, name, name, name, name, name, name, name, name, name, name, name, name });
        return;
    }
    const m = resolved.manifest.?;
    std.debug.print("Usage:\n", .{});
    for (m.commands_allow) |cmd| {
        if (std.mem.eql(u8, cmd, "new")) {
            std.debug.print("  {s} new node <NODE_PREFIX> [--markdown] [-- <TITLE...>]\n", .{name});
            std.debug.print("  {s} new link <LINK_TYPE> <IN_ID> <OUT_ID>\n", .{name});
        } else {
            std.debug.print("  {s} {s}\n", .{ name, cmd });
        }
    }
    for (m.extensions) |ext| {
        std.debug.print("  {s} {s}  # {s}\n", .{ name, ext.name, ext.summary });
    }
}

fn printRegisterUsage() void {
    std.debug.print(
        \\Usage:
        \\  fits register node-type <NODE_PREFIX> [--create-folder]
        \\  fits register link-type <LINK_TYPE> <IN_NODE_TYPE> <OUT_NODE_TYPE> [--create-folder]
        \\  fits register list [node-types|link-types]
        \\  fits register rename-type <OLD> <NEW>
        \\  fits register rm <TYPE> [--force] [--preserve-local] [--cascade]
        \\
    , .{});
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
        const self: *BuiltInValidator = @ptrCast(@alignCast(context));
        _ = self;
        return "builtin.placeholder";
    }

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
