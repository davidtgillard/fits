//! Functional tests for persona command gating.

const std = @import("std");
const persona = @import("../cli/persona.zig");
const persona_manifest = @import("../cli/persona_manifest.zig");

test "default persona allows register and persona admin" {
    var resolved = persona.defaultPersona(std.testing.allocator);
    try std.testing.expect(resolved.allows(.register));
    try std.testing.expect(resolved.allows(.persona));
    try std.testing.expect(resolved.allows(.init));
}

test "demo manifest command allow list" {
    const a = std.testing.allocator;
    const fixture = "test/fixtures/personas/demo";
    const manifest = try persona_manifest.loadFromPackageRoot(a, std.testing.io, fixture);

    var resolved = persona.ResolvedPersona{
        .id = manifest.id,
        .is_default = false,
        .package_root = try a.dupe(u8, fixture),
        .manifest = manifest,
    };
    defer resolved.deinit(a);

    try std.testing.expect(resolved.allows(.validate));
    try std.testing.expect(resolved.allows(.new));
    try std.testing.expect(!resolved.allows(.register));
    try std.testing.expect(!resolved.allows(.init));
    try std.testing.expect(resolved.fixedRegistry());
}
