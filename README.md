# `fits`

`fits` is a Zig command-line tool for working with versioned, folder-based dataset objects. This README only covers how to build the binary and use the CLI today.

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
  fits validate [--hooks] [--hooks-full] [--no-hooks-incremental]
  fits new <OBJ_PREFIX> [--markdown] [-- <TITLE WORDS...>]
  fits new link <LINK_TYPE> <IN_ID> <OUT_ID>
  fits rm <OBJ_ID or LINK_ID>
  fits register obj-type <OBJ_PREFIX> [--create-folder]
  fits register link-type <LINK_TYPE> <IN_OBJ_TYPE> <OUT_OBJ_TYPE> [--create-folder]
  fits register list [obj-types|link-types]
  fits register rename-type <OLD> <NEW>
  fits register new <OBJ_PREFIX>   (deprecated)
  fits register rename <OLD> <NEW>   (deprecated)
  fits update [--check]
  fits version
```

### `fits init`

Creates the standard **fits-managed layout** under the current directory: `.fits/registry.json` (empty prefixes and link types), `.fits/fits_config.toml` (default `update_check_time_period` only), `.fits/latticedb/`, and `relations/links.jsonc` (empty `links` array). **Strict:** if `.fits/registry.json` or `relations/links.jsonc` already exists, the command prints an error and exits without changing files.

```sh
fits init
```

### `fits validate`

Runs the validation pipeline on object bundles under `objects/` and on **`relations/links.jsonc`** (if present). Structural or semantic problems in the links file are printed with JSON-pointer paths before exit. Output also includes a summary line for other validators.

Optional **JSON subprocess hooks** (stdin/stdout) run after the built-in validators when you pass **`--hooks`** and configure `.fits/hooks.toml` with `enabled = true`. See [docs/fits_hooks.md](docs/fits_hooks.md) for the protocol, incremental cache, and flags (`--hooks-full`, `--no-hooks-incremental`).

See [docs/fits_links.md](docs/fits_links.md) for the links file and graph edge rules.

```sh
fits validate
fits validate --hooks
```

### `fits register`

Manages **object type prefixes** and **link types** in `.fits/registry.json`. Object types must be registered before `fits new`; link types must be registered before `fits new link` or before you add matching rows to `relations/links.jsonc` by hand.

The registry format is defined by [`schemas/registry.schema.json`](schemas/registry.schema.json). **Do not edit `.fits/registry.json` by hand.** Field-level detail: [`docs/fits_registry.md`](docs/fits_registry.md). Directed links and `relations/links.jsonc`: [`docs/fits_links.md`](docs/fits_links.md).

#### `fits register obj-type <OBJ_PREFIX> [--create-folder]`

Registers an object type. With `--create-folder`, `fits` records `create_folder = true` under `[obj_types.<PREFIX>]` in `.fits/fits_config.toml` (merged without clobbering other keys).

```sh
fits register obj-type REQ
fits register obj-type SPEC --create-folder
```

#### `fits register link-type <LINK_TYPE> <IN_OBJ_TYPE> <OUT_OBJ_TYPE> [--create-folder]`

Registers a link type: links go **from** `OUT_OBJ_TYPE` instances **to** `IN_OBJ_TYPE` instances. Both object prefixes must already exist. `--create-folder` sets `[link_types.<LINK_TYPE>] create_folder = true` in `.fits/fits_config.toml`.

```sh
fits register obj-type REQ
fits register obj-type DOC
fits register link-type implements REQ DOC --create-folder
```

#### `fits register list [obj-types|link-types]`

With no argument, prints a short header and **both** object and link types. Use `obj-types` or `link-types` to filter.

```sh
fits register list
fits register list obj-types
```

#### `fits register rename-type <OLD> <NEW>`

Renames an **object** prefix (and renames issued instances under `objects/`) or a **link** type (rewrites `relations/links.jsonc` and optional `relations/<id>/` directories). The name must exist in the registry as exactly one of those kinds.

```sh
fits register rename-type REQ FOO
```

#### Deprecated commands

- `fits register new <OBJ_PREFIX>` → use `fits register obj-type`.
- `fits register rename ...` → use `fits register rename-type`.

### `fits new`

Creates a new object under `objects/` using the registry. Each object gets an id of the form `{OBJ_PREFIX}-{n}`, where `n` is a monotonically increasing counter for that prefix (ids are not reused after tombstoning). The object type must already be registered.

- **Layout vs config:** When `--markdown` is not passed, `fits` reads `.fits/fits_config.toml` for `[obj_types.<PREFIX>] create_folder`. If the key is **missing**, behavior matches older releases: an **empty directory** object. If `create_folder = false`, a **Markdown file** is created instead; if `true`, a **directory** is created. `--markdown` always forces a Markdown file.
- **`--markdown`**: Force a Markdown file in the new object path.
- **`--`**: End of flags; everything after it is **title words**, joined with spaces for a human-readable display name suffix.

**Links:** `fits new link <LINK_TYPE> <IN_ID> <OUT_ID>` appends one row to `relations/links.jsonc` with the next issued link id (`{LINK_TYPE}-{n}`). Arguments mirror `fits register link-type`: `IN_ID` must use the registry’s **in** object prefix for that link type and `OUT_ID` the **out** prefix (the stored edge is `{out: OUT_ID, in: IN_ID}`). Both object ids must be issued and not tombstoned. See [`docs/fits_links.md`](docs/fits_links.md).

Examples:

```sh
fits register obj-type REQ
fits new REQ
fits new REQ --markdown
fits new REQ --markdown -- User login flow

fits register obj-type DOC
fits register link-type implements REQ DOC
fits new REQ
fits new DOC
fits new link implements REQ-1 DOC-1
```

### `fits rm`

Removes a **object** or **link** instance by id (e.g. `REQ-3` or `implements-1`). The CLI disambiguates using the registry: object prefixes are checked first, then link types.

**Objects:** matching paths under `objects/` with that numeric suffix are removed.

**Links:** the row is removed from `relations/links.jsonc`; the link numeric id is tombstoned; optional `relations/<link-id>/` is deleted.

The numeric id is **tombstoned** in `.fits/registry.json` so it cannot be reissued. Tombstones use VCS-specific reference fields when removal is recorded in version control:

- **`git_commit`**: full git object name of the removal commit when the repository root is a git repo and the paths were versioned.

When the repo root is a git repository (has `.fits/../.git` at the repo root), `fits rm` runs `git rm` and creates a commit with message `fits rm: {id}`. Without git at the repo root, removal still tombstones the id but omits `git_commit`.

```sh
fits register obj-type REQ
fits new REQ
fits rm REQ-1
fits new REQ          # creates REQ-2, not REQ-1
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

## Exit status

Non-zero exits indicate failures (e.g. invalid arguments, unregistered object type, I/O errors, or validation errors), depending on the subcommand and implementation. `fits update --check` exits `1` when a newer `dev` release is available.
