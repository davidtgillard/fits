# libfits

**libfits** is the Zig repository engine for [fits](https://github.com/davidtgillard/fits)-style repos: versioned **nodes** under type-scoped `nodes/`, **links** in `links/links.jsonc`, and a machine-owned `.fits/registry.json`. A graph **object** is either a node or a link (see [`docs/fits_links.md`](docs/fits_links.md)).

The legacy `fits` CLI and persona host live in a separate repository; this tree builds the library only.

## Prerequisites

- Zig compatible with [`build.zig.zon`](build.zig.zon) (`minimum_zig_version`).

## Build

```sh
zig build
```

Artifacts:

| Output | Description |
|--------|-------------|
| `zig-out/lib/libfits.a` | Static library |
| `zig-out/lib/libfits.so` | Shared library |
| `zig-out/include/fits_core.h` | Struct-based C ABI |
| `zig-out/include/libfits.h` | JSON-over-C ABI |
| `zig-out/schemas/abi/*.schema.json` | JSON Schema for wire payloads |

Schema text is also embedded in the library (`FITS_validate_request_schema()`, etc. in `libfits.h`).

Optional legacy CLI (links this library):

```sh
zig build -Dcli=true
# zig-out/bin/fits
```

## API layers

1. **Zig** — [`src/libfits.zig`](src/libfits.zig): `FitsRepo` and methods (`validate`, `newNode`, …).
2. **C core** — `zig-out/include/fits_core.h` (from [`include/fits_core.h.in`](include/fits_core.h.in)): structs and `FITS_CORE_validate`, `FITS_CORE_new_node`, …
3. **JSON** — [`include/libfits.h`](include/libfits.h): `FITS_validate`, … (see [`docs/abi.md`](docs/abi.md) and [`schemas/abi/`](schemas/abi/)).

Cross-boundary memory uses the C heap; free with `FITS_free()`.

## Tests

```sh
zig build test
zig build abi-test
```

Coverage (kcov):

```sh
KCOV=./tools/kcov zig build coverage
```

## Documentation

- [ABI](docs/abi.md)
- [Registry](docs/fits_registry.md)
- [Links](docs/fits_links.md)
