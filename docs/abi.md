# libfits ABI

libfits exposes two C-compatible layers:

| Header | Role |
|--------|------|
| [`include/fits_core.h.in`](../include/fits_core.h.in) → `zig-out/include/fits_core.h` | Struct-based core API (`FITS_CORE_repo_open`, `FitsValidateResult`, …) |
| [`include/libfits.h`](../include/libfits.h) | JSON request/response wrappers (`FITS_validate`, …) |

JSON payloads are defined under [`schemas/abi/`](../schemas/abi/).

## Naming

Exported C symbols use a screaming prefix and lowercase snake_case tail:

| Prefix | Role | Examples |
|--------|------|----------|
| `FITS_` | Shared helpers and JSON wire API | `FITS_free`, `FITS_validate`, `FITS_remove_obj` |
| `FITS_CORE_` | Struct-based core API | `FITS_CORE_repo_open`, `FITS_CORE_validate`, `FITS_CORE_remove_obj` |

Constants and macros use the `FITS_` prefix throughout (`FITS_OK`, `FITS_ERR_*`, …). Types remain PascalCase (`FitsRepo`, `FitsStatus`).

## Memory

All pointers returned across the C boundary are allocated with the C heap (`malloc`). Free them with `FITS_free()`.

`FITS_CORE_validate_result_destroy()` frees a `FitsValidateResult` and all nested strings.

## Errors

- Core functions return `FitsStatus` (`0` = `FITS_OK`, negative = stable codes in `fits_core.h`).
- After a failure, `FITS_last_error()` may contain a short diagnostic (valid until the next libfits call on the same thread).
- JSON functions always set each operation's `*_response_json` out pointer to a non-null UTF-8 document: success shape or `{ "ok": false, "error": { "code", "message" } }`.

## Struct versioning

Every input struct begins with `uint32_t struct_size` set to `sizeof(ThatStruct)`. libfits rejects unknown sizes.

## Threading

v0: use one `FitsRepo` per thread. Do not share handles across threads without external locking.

## Versioning

- `FITS_api_version()` returns `(major << 16) | minor` for the **C struct layout**.
- `FITS_API_VERSION_*` in `fits_core.h` is generated at build time from `abi_version_major` / `abi_version_minor` in [`build.zig.zon`](../build.zig.zon) (template: [`include/fits_core.h.in`](../include/fits_core.h.in)).
- `FITS_version_string()` returns the package `.version` field from the same manifest.
- JSON bodies include `protocol_version` (currently `1`) for payload shape.

Bump `abi_version_major` when any exported struct field order or meaning changes; bump `abi_version_minor` for compatible additions. Bump JSON `protocol_version` when request/response JSON changes.

## Build artifacts

`zig build` produces:

- `zig-out/lib/libfits.a` (static)
- `zig-out/lib/libfits.so` (shared)
- `zig-out/include/fits_core.h`, `libfits.h`
- `zig-out/schemas/abi/*.schema.json` (JSON Schema documents for the wire API, installed from `schemas/abi/`)

The same schema files are also available in-process via `FITS_*_schema()` accessors declared in `libfits.h` (for example `FITS_validate_request_schema()`). Returned pointers have static storage; do not call `FITS_free()` on them. The library embeds bytes from `src/schemas/abi/` (kept in sync with `schemas/abi/`).

Optional CLI (legacy): `zig build -Dcli=true` installs the `fits` executable linked against the static library.
