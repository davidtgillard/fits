# Personas (legacy)

> **Note:** Persona host support (`fits` symlink, `persona.toml` dispatch) is being removed from **libfits**. Personas will be implemented in the separate **fits-python** repository using `libfits.h`. This document is retained for reference until that migration is complete.

A **persona** is a named product built on top of the same `fits` binary. Users run `foo` (a symlink to `fits`); the host loads a **persona package** from disk at runtime. The `fits` source tree never compiles in knowledge of any specific persona.

See also: [fits_hooks.md](fits_hooks.md) (validation protocol), [fits_registry.md](fits_registry.md), [fits_links.md](fits_links.md), and the canonical demo package at [`test/fixtures/personas/demo/`](../test/fixtures/personas/demo/).

## Quick start

1. Create a persona package directory (see layout below).
2. Install it globally:

   ```sh
   fits persona install /path/to/my-persona
   ```

3. Symlink the binary name:

   ```sh
   ln -s "$(command -v fits)" ~/.local/bin/foo
   ```

4. In a consumer repository, add `fits.zon` and a committed `.fits/registry.json` matching your snapshot.

   ```zig
   .{
       .persona = "foo",
       .persona_min_version = "1.0.0",
   }
   ```

5. Users run `foo validate`, `foo new node REQ`, etc.

## Persona package layout

```
my-persona/
  persona.toml              # required manifest
  registry.snapshot.json    # required when [registry] mode = "fixed"
  bin/                      # optional; hook and extension executables
    my-validate
    my-export
```

## How invocation works

| Invocation | Behavior |
|------------|----------|
| `fits` | Full generic CLI (`init`, `register`, `validate`, `new`, `rm`, `update`, `version`, `persona …`) |
| `foo` (symlink to `fits`) | Commands allowed in `persona.toml`; persona `version`; fixed registry; persona hooks |

Persona selection uses **`argv[0]` basename only** (not the first subcommand).

### Resolution order

When the basename is not `fits`, the host searches for `persona.toml` in this order:

1. **Repo-local:** `.fits/personas/<id>/persona.toml` (walk up from cwd)
2. **Repo binding:** `fits.zon` with `.persona = "<id>"` (then global/env paths below)
3. **Global:** `~/.config/fits/personas/<id>/persona.toml`
4. **Environment:** `$FITS_PERSONA_PATH/<id>/persona.toml`

If `fits.zon` declares a different `.persona` than the executable name, the command fails with a clear error.

## `persona.toml` reference

### Top-level

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Persona id (must match executable basename, e.g. `foo`) |
| `version` | yes | Persona release version (shown by `foo version`) |
| `fits_min_version` | yes | Minimum compatible `fits` version (e.g. `0.1.0`) |

### `[cli]`

| Field | Description |
|-------|-------------|
| `description` | Short text for help output |

### `[commands]`

| Field | Description |
|-------|-------------|
| `allow` | JSON array of allowed subcommands, e.g. `["validate", "new", "rm", "version"]` |

Common persona allow lists omit `init`, `register`, and `update`.

### `[[commands.extension]]`

| Field | Description |
|-------|-------------|
| `name` | Subcommand name (e.g. `export`) |
| `summary` | One-line help text |
| `run` | JSON argv array; program resolved under package `bin/` then `PATH` |

### `[registry]`

| Field | Description |
|-------|-------------|
| `mode` | `fixed` (default) or `mutable` |
| `snapshot` | Path to snapshot JSON relative to package root (default `registry.snapshot.json`) |

**Fixed mode:** before `new`, `new link`, and `rm`, the host verifies that `.fits/registry.json` matches the snapshot (node types—including abstract/concrete shape—and link types/endpoints; counters and tombstones are ignored). `fits new node` is gated on **id prefixes** present in the snapshot.

### `[validate]`

| Field | Default | Description |
|-------|---------|-------------|
| `hooks_default` | `true` | Run persona hooks on `validate` |
| `include_link_endpoints` | `true` | Run built-in link endpoint validator |

### `[[validate.hook]]`

| Field | Description |
|-------|-------------|
| `nodes_command` | JSON argv for node validation hook |
| `links_command` | JSON argv for link validation hook |
| `timeout_secs` | Optional subprocess timeout |

**Hook precedence:** for named personas, hooks come from the persona manifest when `hooks_default = true`. Repo `.fits/hooks.toml` is not used for named personas in the MVP.

Hook programs use the [JSON hooks protocol](fits_hooks.md). Resolve paths: package `bin/<program>` first, then `PATH`.

### Example

```toml
id = "foo"
version = "1.0.0"
fits_min_version = "0.1.0"

[cli]
description = "Example product CLI"

[commands]
allow = ["validate", "new", "rm", "version"]

[[commands.extension]]
name = "export"
summary = "Export graph"
run = ["foo-export"]

[registry]
mode = "fixed"
snapshot = "registry.snapshot.json"

[validate]
hooks_default = true
include_link_endpoints = true

[[validate.hook]]
nodes_command = ["foo-validate", "nodes"]
links_command = ["foo-validate", "links"]
```

## Registry snapshot (maintainers)

1. In a scratch or product repo, use **`fits`** (not the persona name):

   ```sh
   fits init
   fits register node-type REQ
   fits register link-type traces REQ REQ
   ```

2. Copy `.fits/registry.json` to your persona package as `registry.snapshot.json`. Strip or reset `next` and `tombstones` if you want a minimal template; the host compares **types only**.

3. Commit `.fits/registry.json` in consumer repos so instance commands work offline.

End users should not run `register` via the persona CLI; maintainers use `fits register` when evolving types.

## Validation and parsing

- **Structural validation** (registry, links file, link endpoints) runs in the host.
- **Semantic validation** is implemented as **hooks** (see [fits_hooks.md](fits_hooks.md)).
- **Parsing** node file contents: implement inside your **nodes** hook in the MVP (inspect bundle payloads in the hook request JSON).

## Extension commands

Extensions run as subprocesses with cwd = process cwd (run from repo root). Environment variables:

| Variable | Value |
|----------|--------|
| `FITS_REPO_ROOT` | Absolute or relative repo root (`.` when invoked from repo) |
| `FITS_PERSONA_ID` | Persona id |
| `FITS_PERSONA_VERSION` | Persona manifest version |

Non-zero exit status propagates as command failure.

## Installation

```sh
# Copy package to ~/.config/fits/personas/<id>/
fits persona install /path/to/my-persona

# Development: symlink instead of copy
fits persona install /path/to/my-persona --link

fits persona list
fits persona info foo
```

**Repo-local:** copy or symlink the package to `.fits/personas/<id>/` in the repository.

**`FITS_PERSONA_PATH`:** directory containing one subdirectory per persona id (each with `persona.toml`).

## Consumer vs maintainer workflows

| Task | Maintainer (`fits`) | End user (`foo`) |
|------|---------------------|------------------|
| Initialize repo | `fits init` | — |
| Register types | `fits register …` | — |
| Create instances | `fits new node …` | `foo new node …` |
| Validate | `fits validate` | `foo validate` (persona hooks automatic when configured) |
| Remove | `fits rm …` | `foo rm …` |
| Persona version | `fits version` (fits build) | `foo version` |

## Versioning

- **`foo version`** prints `persona.toml` `version`, not the fits git commit.
- **`fits version`** prints the fits build identity and update source.
- **`fits_min_version`** in the manifest is checked against the running fits build.
- **`fits.zon`** may set `.persona_min_version` for repo-level policy (checked against fits build when present).

## Testing your persona

1. Use the demo fixture as a template: [`test/fixtures/personas/demo/`](../test/fixtures/personas/demo/).
2. Point `FITS_PERSONA_PATH` at the parent of your persona id directory:

   ```sh
   export FITS_PERSONA_PATH=/path/to/personas
   ln -s "$(command -v fits)" ./foo
   ```

3. Golden-test hook stdin/stdout against [schemas/hooks_request.schema.json](../schemas/hooks_request.schema.json) and [schemas/hooks_response.schema.json](../schemas/hooks_response.schema.json).

## Troubleshooting

| Problem | Likely cause |
|---------|----------------|
| `persona 'foo' not found` | Package not installed; run `fits persona install` or set `FITS_PERSONA_PATH` |
| `manifest id does not match executable name` | `id` in `persona.toml` must equal symlink basename |
| `fits.zon declares persona X but executable is Y` | Fix `.persona` or symlink name |
| `registry snapshot mismatch` | `.fits/registry.json` differs from `registry.snapshot.json` |
| Hooks not running | Check `hooks_default`, `[[validate.hook]]`, and `bin/` paths |
| `command 'register' is not available` | Expected for personas; use `fits register` as maintainer |

## Roadmap (not in MVP)

- In-process `.so` / WASM plugins
- `fits persona publish` and persona self-update
- Dedicated parse-hook kind in the manifest
- `extension_graph_api` RPC for graph queries from hooks
