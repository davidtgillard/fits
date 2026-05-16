//! Persona identity and command policy loaded at runtime (not compiled into fits for specific products).

const persona_manifest = @import("persona_manifest.zig");

/// Subcommand names exposed through the CLI host.
pub const Command = enum {
    init,
    validate,
    new,
    rm,
    register,
    update,
    version,
    persona,
};

/// Resolved persona for the current process (default `fits` or a named package).
pub const ResolvedPersona = struct {
    /// Persona id (`fits` for the default CLI).
    id: []const u8,
    /// When true, use the built-in full fits command surface.
    is_default: bool,
    /// Package root directory (owned; empty for default persona).
    package_root: []const u8,
    /// Parsed manifest (owned when `!is_default`).
    manifest: ?persona_manifest.PersonaManifest,

    /// Frees `package_root` and manifest storage (`id` points into manifest or is `"fits"`).
    pub fn deinit(self: *const ResolvedPersona, allocator: std.mem.Allocator) void {
        const mut: *ResolvedPersona = @constCast(self);
        if (mut.package_root.len != 0) allocator.free(mut.package_root);
        if (mut.manifest) |*m| m.deinit(allocator);
        mut.* = undefined;
    }

    /// Returns whether `cmd` is allowed for this persona.
    pub fn allows(self: *const ResolvedPersona, cmd: Command) bool {
        if (self.is_default) return true;
        const m = self.manifest orelse return false;
        const name = commandName(cmd);
        for (m.commands_allow) |allowed| {
            if (std.mem.eql(u8, allowed, name)) return true;
        }
        return false;
    }

    /// True when this persona should spawn fits background update checks.
    pub fn backgroundUpdateCheck(self: *const ResolvedPersona) bool {
        return self.is_default;
    }

    /// True when registry must match `registry.snapshot.json`.
    pub fn fixedRegistry(self: *const ResolvedPersona) bool {
        if (self.is_default) return false;
        const m = self.manifest orelse return false;
        return m.registry_mode == .fixed;
    }

    fn commandName(cmd: Command) []const u8 {
        return switch (cmd) {
            .init => "init",
            .validate => "validate",
            .new => "new",
            .rm => "rm",
            .register => "register",
            .update => "update",
            .version => "version",
            .persona => "persona",
        };
    }
};

const std = @import("std");

/// Builds the default fits persona (no package on disk).
pub fn defaultPersona(allocator: std.mem.Allocator) ResolvedPersona {
    _ = allocator;
    return .{
        .id = "fits",
        .is_default = true,
        .package_root = &.{},
        .manifest = null,
    };
}
