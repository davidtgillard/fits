# `fits`

`fits` is a Zig command-line tool for working with versioned, folder-based dataset **nodes** (instances under type-scoped `nodes/`). In fits terminology, a **graph object** is either a **node** or a **link** (see [`docs/fits_links.md`](docs/fits_links.md)). This README only covers how to build the binary and use the CLI today.

## Prerequisites

- A recent [Zig](https://ziglang.org/) toolchain compatible with this repository’s `build.zig.zon` (see `minimum_zig_version` there).

## Build

From the repository root:

```sh
zig build
```

The `fits` executable is produced under `zig-out/bin/` (e.g. `zig-out/bin/fits`). You can run it via the build step:

```sh
zig build run -- validate
```

## CLI overview

Invoke `fits` with a subcommand. If you omit the subcommand or pass an unknown one, the tool prints a short usage summary.

```text
Usage:
  fits init
  fits validate [--dry-run] [--hooks-full-graph]
  fits new node <NODE_PREFIX> [--markdown] [-- <TITLE WORDS...>]
  fits new link <LINK_TYPE> <IN_ID> <OUT_ID>
  fits rm <NODE_ID or LINK_ID>
  fits register node-type <TYPE> [--abstract | --extends <ABSTRACT>] [--create-folder]
  fits register link-type <LINK_TYPE> <IN_TYPE> <OUT_TYPE> [--create-folder]
  fits register list [node-types|link-types]
  fits register rename-type <OLD> <NEW>
  fits register new <NODE_PREFIX>   (deprecated)
  fits register rename <OLD> <NEW>   (deprecated)
  fits update [--check]
  fits version
```

### `fits init`

Creates the standard **fits-managed layout** under the current directory: `.fits/registry.json` (empty `node_types` and `link_types`), `.fits/fits_config.toml` (default `update_check_time_period` only), `.fits/latticedb/`, and `links/links.jsonc` (empty `links` array). **Strict:** if `.fits/registry.json` or `links/links.jsonc` already exists, the command prints an error and exits without changing files.

```sh
fits init
```

### `fits validate`

Runs the validation pipeline on **node** bundles under `nodes/` and on **`links/links.jsonc`** (if present). Structural or semantic problems in the links file are printed with JSON-pointer paths before exit. Output also includes a summary line for other validators.

Optional **JSON subprocess hooks** (stdin/stdout) run after the built-in validators when `.fits/hooks.toml` has `enabled = true` (or when a persona defines validate hooks with `hooks_default = true`). See [docs/fits_hooks.md](docs/fits_hooks.md) for the protocol, incremental cache, and flags (`--dry-run`, `--hooks-full-graph`).

See [docs/fits_links.md](docs/fits_links.md) for the links file and graph edge rules.

```sh
fits validate
```

### `fits register`

Manages **node types** (abstract and concrete) and **link types** in `.fits/registry.json`. Concrete node types must be registered before `fits new node`; link types must be registered before `fits new link` or before you add matching rows to `links/links.jsonc` by hand.

The registry format is defined by [`schemas/registry.schema.json`](schemas/registry.schema.json). **Do not edit `.fits/registry.json` by hand.** Field-level detail: [`docs/fits_registry.md`](docs/fits_registry.md). Directed links and `links/links.jsonc`: [`docs/fits_links.md`](docs/fits_links.md).

#### `fits register node-type <TYPE> [--abstract | --extends <ABSTRACT>] [--create-folder]`

Registers a node type in the registry:

- **`--abstract`**: uninstantiable type (no instance allocation, no counter). Mutually exclusive with `--extends`.
- **`--extends <ABSTRACT>`**: concrete type that extends an existing **abstract** parent. Omit for a standalone concrete type (folder at `nodes/<type>/`).
- **`--create-folder`**: for concrete types only; sets `create_folder = true` under `[obj_types.<ID_PREFIX>]` in `.fits/fits_config.toml`.

```sh
fits register node-type req --abstract
fits register node-type REQ --extends req
fits register node-type SPEC --extends req --create-folder
```

#### `fits register link-type <LINK_TYPE> <IN_TYPE> <OUT_TYPE> [--create-folder]`

Registers a link type: links go **from** `OUT_TYPE` node instances **to** `IN_TYPE` instances. `IN_TYPE` and `OUT_TYPE` are registry **type names** (abstract or concrete), not id prefixes. Both must already be registered. `--create-folder` sets `[link_types.<LINK_TYPE>] create_folder = true` in `.fits/fits_config.toml`.

```sh
fits register node-type doc --abstract
fits register node-type DOC --extends doc
fits register link-type implements req DOC --create-folder
```

#### `fits register list [node-types|link-types]`

With no argument, prints a short header and **both** node and link types. Use `node-types` or `link-types` to filter.

```sh
fits register list
fits register list node-types
```

#### `fits register rename-type <OLD> <NEW>`

Renames a **node type** (abstract or concrete; renames issued instances under the type’s `nodes/…` folder when the concrete `id_prefix` matches the old type name) or a **link** type (rewrites `links/links.jsonc` and optional `links/<link-type>/<id>/` directories). The name must exist in the registry as exactly one of those kinds.

```sh
fits register rename-type REQ FOO
```

#### `fits register rm <TYPE> [--force] [--preserve-local] [--cascade]`

Unregisters a **node type** (abstract or concrete) or **link** type. Without `--force`, the command fails if any live instances exist in the registry or on disk (under `nodes/…` for concrete nodes; `links/links.jsonc` and `links/<link-type>/<id>/` for links). Abstract types cannot be removed while concrete children or referencing link types exist unless **`--force --cascade`**.

- **`--force`**: remove non-tombstoned instances, then drop the type from `.fits/registry.json` and optional config keys.
- **`--preserve-local`**: with `--force`, update the registry and link index but leave files under `nodes/` and `links/` on disk.
- **`--cascade`**: with `--force` on a **node type**, also remove dangling link rows, unregister link types that reference the type (or its id prefixes), and for **abstract** types remove all concrete children first. Required when `--force` would otherwise leave dangling links or child types.

Tombstoned numeric ids are never deleted from disk, regardless of flags.

```sh
fits register rm REQ
fits register rm REQ --force
fits register rm REQ --force --cascade
fits register rm implements --force
```

#### Deprecated commands

- `fits register new <NODE_PREFIX>` → use `fits register node-type`.
- `fits register obj-type` / `fits register list obj-types` → use `node-type` / `node-types`.
- `fits register rename ...` → use `fits register rename-type`.

### `fits new`

#### `fits new node <NODE_PREFIX> [--markdown] [-- <TITLE WORDS...>]`

Creates a new **node** under the concrete type’s folder in `nodes/` (e.g. `nodes/req/REQ/REQ-1/`). Each node gets an id of the form `{ID_PREFIX}-{n}`, where `n` is a monotonically increasing counter for that concrete type’s id prefix (ids are not reused after tombstoning). The id prefix must belong to a **concrete** registered type.

- **Layout vs config:** When `--markdown` is not passed, `fits` reads `.fits/fits_config.toml` for `[obj_types.<PREFIX>] create_folder`. If the key is **missing**, behavior matches older releases: an **empty directory** node. If `create_folder = false`, a **Markdown file** is created instead; if `true`, a **directory** is created. `--markdown` always forces a Markdown file.
- **`--markdown`**: Force a Markdown file in the new node path.
- **`--`**: End of flags; everything after it is **title words**, joined with spaces for a human-readable display name suffix.

**Links:** `fits new link <LINK_TYPE> <IN_ID> <OUT_ID>` appends one row to `links/links.jsonc` with the next issued link id (`{LINK_TYPE}-{n}`). Endpoint node ids must match the registered **in** / **out** types for that link type (abstract endpoints accept any concrete type extending that abstract). The stored edge is `{out: OUT_ID, in: IN_ID}`. Both node ids must be issued and not tombstoned. See [`docs/fits_links.md`](docs/fits_links.md).

Examples:

```sh
fits register node-type req --abstract
fits register node-type REQ --extends req
fits new node REQ
fits new node REQ --markdown
fits new node REQ --markdown -- User login flow

fits register node-type doc --abstract
fits register node-type DOC --extends doc
fits register link-type implements req DOC
fits new node REQ
fits new node DOC
fits new link implements DOC-1 REQ-1
```

### `fits rm`

Removes a graph **object** (a **node** under `nodes/…` or a **link** row) by id (e.g. `REQ-3` or `implements-1`). The CLI disambiguates using the registry: concrete id prefixes are checked first, then link types.

**Nodes:** matching instance paths under the type’s `nodes/…` folder are removed.

**Links:** the row is removed from `links/links.jsonc`; the link numeric id is tombstoned; optional `links/<link-type>/<link-id>/` is deleted.

The numeric id is **tombstoned** in `.fits/registry.json` so it cannot be reissued. Tombstones use VCS-specific reference fields when removal is recorded in version control:

- **`git_commit`**: full git object name of the removal commit when the repository root is a git repo and the paths were versioned.

When the repo root is a git repository (has `.fits/../.git` at the repo root), `fits rm` runs `git rm` and creates a commit with message `fits rm: {id}`. Without git at the repo root, removal still tombstones the id but omits `git_commit`.

```sh
fits register node-type req --abstract
fits register node-type REQ --extends req
fits new node REQ
fits rm REQ-1
fits new node REQ          # creates REQ-2, not REQ-1
```

To inspect removal history in git:

```sh
git show <git_commit from .fits/registry.json>
```

### `fits version`

Prints the git commit baked in at build time (CI releases) or `unknown (local build)` for `zig build` on your machine.

```sh
fits version
```

### `fits update`

Linux-only self-update from the rolling GitHub Release tagged `dev` (published on every push to `main`). CI builds attach `fits` and `manifest.json` (`git_commit`, `sha256`).

```sh
fits update --check   # compare with dev release; exit 1 if newer
fits update           # download, verify checksum, replace running binary
```

Local `zig build` binaries cannot self-update (no embedded commit). Install a CI-built binary to use updates.

**Background checks:** On most commands, `fits` may spawn a detached `fits update --background` at most once per `update_check_time_period` (default 1 day). Configure in `.fits/fits_config.toml` when that directory exists, otherwise `~/.config/fits/fits_config.toml`:

```toml
update_check_time_period = 86400   # seconds; "1d" is also accepted

[obj_types.REQ]
create_folder = true

[link_types.implements]
create_folder = true
```

Last-check time is stored in the LatticeDB cache (`.fits/latticedb/` in a repository that uses `fits`, or `~/.fits/latticedb/` globally).

Set `FITS_NO_UPDATE_CHECK=1` to disable background checks. For private repos, set `FITS_GITHUB_TOKEN` or `GITHUB_TOKEN`.

Manual download:

```sh
gh release download dev -R davidtgillard/fits -p fits -p manifest.json
```

## Personas

The same `fits` binary can act as a **named product** (e.g. `foo`) when invoked via a symlink. Persona behavior is loaded at runtime from a package on disk (`persona.toml`, registry snapshot, hook binaries). Install with `fits persona install`, then `ln -s fits foo`.

See **[docs/personas.md](docs/personas.md)** for how to author a persona, and **[docs/personas_implementation_plan.md](docs/personas_implementation_plan.md)** for the internal implementation plan.

## Exit status

Non-zero exits indicate failures (e.g. invalid arguments, unregistered node type, I/O errors, or validation errors), depending on the subcommand and implementation. `fits update --check` exits `1` when a newer `dev` release is available.
