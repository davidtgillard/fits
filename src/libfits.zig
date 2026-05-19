//! libfits: repository engine as a Zig library with C ABI (`fits_core.h`, `libfits.h`).

pub const FitsRepo = @import("libfits/repo.zig").FitsRepo;
pub const OpenOptions = @import("libfits/repo.zig").OpenOptions;
pub const ValidateOptions = @import("libfits/repo.zig").ValidateOptions;

comptime {
    _ = @import("libfits/c_core.zig");
    _ = @import("libfits/c_json.zig");
    _ = @import("libfits/c_schemas.zig");
}

test {
    _ = @import("adapters/fs/fits_registry.zig");
    _ = @import("adapters/fs/registry_validate.zig");
    _ = @import("adapters/fs/fits_config.zig");
    _ = @import("adapters/cache/fits_cache.zig");
    _ = @import("app/new_link.zig");
    _ = @import("app/new_node.zig");
    _ = @import("app/register.zig");
    _ = @import("app/init_repo.zig");
    _ = @import("test/fits_registry_functional.zig");
    _ = @import("test/new_link_functional.zig");
    _ = @import("test/new_node_functional.zig");
    _ = @import("test/register_functional.zig");
    _ = @import("test/register_rm_functional.zig");
    _ = @import("test/links_functional.zig");
    _ = @import("test/remove_object_functional.zig");
    _ = @import("test/init_functional.zig");
    _ = @import("adapters/git/removal.zig");
    _ = @import("domain/instance_id.zig");
    _ = @import("domain/graph_subgraph.zig");
    _ = @import("domain/hook_protocol.zig");
    _ = @import("adapters/hooks/git_dirty.zig");
    _ = @import("adapters/hooks/hook_request.zig");
    _ = @import("adapters/hooks/graph_json.zig");
    _ = @import("test/output_graph_functional.zig");
    _ = @import("adapters/fs/registry_snapshot.zig");
    _ = @import("libfits/c_core.zig");
    _ = @import("libfits/c_json.zig");
    _ = @import("libfits/c_schemas.zig");
    _ = @import("test/libfits_abi_functional.zig");
}
