# Personas MVP — implementation plan

## Goal

Ship a single **`fits` binary** that acts as a named product when invoked via **`argv[0]`** (e.g. `ln -s fits foo`). Persona behavior is loaded at **runtime** from a **persona package** on disk (manifest + assets). The `fits` source tree never embeds or compiles knowledge of any specific persona.

**MVP scope:** manifest (`persona.toml`) + fixed registry snapshot + subprocess hooks + extension commands. **Out of scope:** separate `foo` binary, `dlopen` plugins, persona self-update.

## Architecture

| Invocation | Persona | Behavior |
|------------|---------|----------|
| `fits` | default | Current CLI: `init`, `register`, `validate`, `new`, `rm`, `update`, `version`, `persona` |
| `foo` (symlink) | resolved package | Commands from manifest `allow`; fixed registry; persona hooks; persona `version` |

**Resolution order** (first hit wins):

1. Repo: `.fits/personas/<id>/persona.toml`
2. Repo: `fits.zon` `.persona` must match `<id>` when present (package still resolved via paths 1, 3, 4)
3. Global: `~/.config/fits/personas/<id>/persona.toml`
4. Env: `FITS_PERSONA_PATH/<id>/persona.toml`

**Policy:** Persona is selected **only** by `argv[0]` basename, not when invoked as `fits`.

## Persona package format

```
my-persona/
  persona.toml
  registry.snapshot.json
  bin/
    my-validate
```

## Implementation phases

See git history for phase completion. Modules live under `src/cli/` and `src/adapters/fs/`.

## MVP success criteria

- `ln -s fits foo` + `fits persona install ./demo-persona` → `foo version` shows persona version
- `foo register` / `foo init` rejected with clear message
- `foo new node` / `foo rm` work when registry matches snapshot
- `foo validate` runs structural + persona hooks without `--hooks`
- `foo <extension>` runs declared binary
- `fits` behavior unchanged for generic repos
- [`personas.md`](personas.md) complete for implementers

## Locked decisions

| Topic | Choice |
|-------|--------|
| Persona selection | `argv[0]` basename only |
| Persona artifact | Package directory, not second binary |
| MVP validation | Subprocess hooks ([fits_hooks.md](fits_hooks.md)) |
| Registry | `fixed` + strict snapshot match |
| Manifest format | TOML (`persona.toml`) |
| Hook precedence | Persona manifest hooks when `hooks_default = true`; repo `.fits/hooks.toml` not merged for named personas |

## Post-MVP

- In-process `.so` / WASM plugins
- `fits persona publish` / persona self-update
- Dedicated parse hook kind
- `extension_graph_api` RPC
