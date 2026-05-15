//! FITS CLI: dispatches subcommands and wires adapters to validate and object-creation flows.

const std = @import("std");
const loader_mod = @import("adapters/fs/loader.zig");
const ignore_mod = @import("adapters/git/ignore.zig");
const cache_mod = @import("adapters/cache/latticedb_cache.zig");
const graph_builder_mod = @import("domain/graph_builder.zig");
const validation = @import("domain/validation.zig");
const use_case_mod = @import("app/validate_use_case.zig");
const report_mod = @import("output/report.zig");
const new_object_mod = @import("app/new_object.zig");
const register_mod = @import("app/register.zig");
const remove_object_mod = @import("app/remove_object.zig");

/// Program entry: parses argv, runs a subcommand, prints usage on unknown input.
///
/// Parameters:
/// - `init`: Process bootstrap (allocator, args, I/O, etc.) from the Zig runtime.
///
/// Returns: nothing on success. On failure: argument parsing errors (including [`error.InvalidArgv`]),
/// validate pipeline errors, render errors, or registry / filesystem errors from other commands.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip executable name (argv[0]).
    const cmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "validate")) {
        try runValidate(allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "new")) {
        try runNew(allocator, init.io, &args);
        return;
    }

    if (std.mem.eql(u8, cmd, "register")) {
        try runRegister(allocator, init.io, &args);
        return;
    }

    if (std.mem.eql(u8, cmd, "rm")) {
        try runRm(allocator, init.io, &args);
        return;
    }

    printUsage();
}

// Loads bundles, runs validate use-case, prints a text summary line.
fn runValidate(allocator: std.mem.Allocator) !void {
    const ignore = ignore_mod.IgnoreMatcher.init(".");
    const loader = loader_mod.Loader.init(ignore);
    const bundles = try loader.loadObjectBundles(allocator, ".", "objects");
    defer allocator.free(bundles);

    var deterministic_builder = graph_builder_mod.DeterministicGraphBuilder{};
    var cache = cache_mod.LatticeDbCache.init(allocator);
    var built_in = BuiltInValidator{};

    const validators = [_]validation.Validator{built_in.asInterface()};
    var registry = use_case_mod.StaticValidatorRegistry{
        .validators = validators[0..],
    };

    const use_case = use_case_mod.ValidateUseCase{
        .allocator = allocator,
        .graph_builder = deterministic_builder.asInterface(),
        .validator_registry = registry.asInterface(),
        .cache_store = cache.asInterface(),
    };

    const report = try use_case.execute(bundles);
    defer allocator.free(report.findings);

    var renderer = report_mod.TextRenderer{};
    try renderer.asInterface().render(report);
}

// Prints supported commands to stderr via the debug print path.
fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  fits validate
        \\  fits new <OBJ_PREFIX> [--markdown] [-- <TITLE WORDS...>]
        \\  fits register new <OBJ_PREFIX>
        \\  fits register list
        \\  fits register rename <OLD_OBJ_PREFIX> <NEW_OBJ_PREFIX>
        \\  fits rm <OBJ_NAME>
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
        \\  fits register new <OBJ_PREFIX>
        \\  fits register list
        \\  fits register rename <OLD_OBJ_PREFIX> <NEW_OBJ_PREFIX>
        \\
    , .{});
}

// Parses `fits new` argv and delegates to [`new_object_mod.run`].
fn runNew(allocator: std.mem.Allocator, io: std.Io, args: anytype) !void {
    const obj_prefix = args.next() orelse {
        printUsage();
        return error.InvalidArgv;
    };

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

    try new_object_mod.run(allocator, io, new_object_mod.default_repo_root, new_object_mod.default_objects_dir, obj_prefix, .{
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

    if (std.mem.eql(u8, sub, "list")) {
        if (args.next() != null) {
            printRegisterUsage();
            return error.InvalidArgv;
        }
        try register_mod.runList(allocator, io, register_mod.default_repo_root);
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
    _ = @import("app/new_object.zig");
    _ = @import("app/register.zig");
    _ = @import("test/fits_registry_functional.zig");
    _ = @import("test/new_object_functional.zig");
    _ = @import("test/register_functional.zig");
    _ = @import("test/remove_object_functional.zig");
    _ = @import("test/tombstone_cache_functional.zig");
    _ = @import("adapters/git/removal.zig");
    _ = @import("domain/instance_id.zig");
    _ = @import("adapters/cache/tombstone_cache.zig");
}
