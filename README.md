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

Invoke `fits` with a subcommand. If you omit the subcommand or pass an unknown one, FITS prints a short usage summary.

```text
Usage:
  fits validate
  fits new <OBJ_PREFIX> [--markdown] [-- <TITLE WORDS...>]
  fits rm <OBJ_NAME>
  fits register new <OBJ_PREFIX>
  fits register list
  fits register rename <OLD_OBJ_PREFIX> <NEW_OBJ_PREFIX>
  fits update [--check]
  fits version
```

### `fits validate`

Runs the validation pipeline on object bundles discovered under the default layout (repository root `.`, objects directory `objects/`). Output is a single summary line to stderr (via the debug print path), listing total findings and counts by severity.

Today this path is still backed by early scaffolding (e.g. empty bundle lists until full scanning is implemented); the command exists so CI and local workflows can call a stable interface.

```sh
fits validate
```

### `fits register`

Manages object type prefixes in the machine-owned registry at `.fits/registry.json`. Object types must be registered before you can create instances with `fits new`.

The registry format is defined by [`schemas/registry.schema.json`](schemas/registry.schema.json). If the file is invalid, `fits` prints every structural problem (path and message) to stderr before exiting. See [`docs/fits_registry.md`](docs/fits_registry.md) for field-level detail. **Do not edit `.fits/registry.json` by hand** — only the `fits` CLI should change it.

#### `fits register new <OBJ_PREFIX>`

Registers a new object type prefix. Prefix rules: starts with an ASCII letter, then letters, digits, or underscore.

```sh
fits register new REQ
```

#### `fits register list`

Lists all registered object type prefixes and their `next` counter (tab-separated: prefix, next).

```sh
fits register list
```

#### `fits register rename <OLD_OBJ_PREFIX> <NEW_OBJ_PREFIX>`

Renames an object type in the registry and renames `fits`-managed instances under `objects/`. Only instances whose numeric suffix `n` is in the issued range for the old prefix (`1 <= n < next` in the registry before rename) are renamed. Other paths that look like `OLD-*` but fall outside that range are left untouched and reported as warnings (assumed created outside `fits`).

```sh
fits register rename REQ FOO
```

### `fits new`

Creates a new object under `objects/` using the registry. Each object gets an id of the form `{OBJ_PREFIX}-{n}`, where `n` is a monotonically increasing counter for that prefix (ids are not reused after deletion). The object type must already be registered with `fits register new`.

- **`<OBJ_PREFIX>`** (required): A short prefix for the object type (validated; must exist in the registry).
- **`--markdown`**: Create a Markdown file in the new object directory instead of an empty directory-only object.
- **`--`**: End of flags; everything after it is treated as **title words**, joined with spaces for a human-readable display name suffix.

Examples:

```sh
fits register new REQ
fits new REQ
fits new REQ --markdown
fits new REQ --markdown -- User login flow
```

### `fits rm`

Removes a `fits` object instance by canonical id `{OBJ_PREFIX}-{n}` (e.g. `REQ-3`). All matching paths under `objects/` with that numeric suffix are removed (directories, markdown files, or titled variants).

The numeric id is **tombstoned** in `.fits/registry.json` so it cannot be reissued. Tombstones use VCS-specific reference fields when removal is recorded in version control:

- **`git_commit`**: full git object name of the removal commit when the repository root is a git repo and the paths were versioned.

A mirror of tombstones is kept in `.fits/tombstone_cache.json` for fast local lookup.

When the repo root is a git repository (has `.fits/../.git` at the repo root), `fits rm` runs `git rm` and creates a commit with message `fits rm: {OBJ_NAME}`. Without git at the repo root, removal still tombstones the id but omits `git_commit`.

```sh
fits register new REQ
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
```

Last-check time is stored in the LatticeDB cache (`.fits/latticedb/` in a FITS repo, or `~/.fits/latticedb/` globally).

Set `FITS_NO_UPDATE_CHECK=1` to disable background checks. For private repos, set `FITS_GITHUB_TOKEN` or `GITHUB_TOKEN`.

Manual download:

```sh
gh release download dev -R davidtgillard/fits -p fits -p manifest.json
```

## Exit status

Non-zero exits indicate failures (e.g. invalid arguments, unregistered object type, I/O errors, or validation errors), depending on the subcommand and implementation. `fits update --check` exits `1` when a newer `dev` release is available.
