# libfits ABI

libfits exposes two C-compatible layers:

| Header | Role |
|--------|------|
| [`include/fits_core.h`](../include/fits_core.h) | Struct-based core API (`FitsRepo`, `FitsValidateResult`, …) |
| [`include/libfits.h`](../include/libfits.h) | JSON request/response wrappers (`libfits_validate_json`, …) |

JSON payloads are defined under [`schemas/abi/`](../schemas/abi/).

## Memory

All pointers returned across the C boundary are allocated with the C heap (`malloc`). Free them with `fits_free()`.

`fits_validate_result_destroy()` frees a `FitsValidateResult` and all nested strings.

## Errors

- Core functions return `FitsStatus` (`0` = `FITS_OK`, negative = stable codes in `fits_core.h`).
- After a failure, `fits_last_error()` may contain a short diagnostic (valid until the next libfits call on the same thread).
- JSON functions always set `*response_json` to a non-null UTF-8 document: success shape or `{ "ok": false, "error": { "code", "message" } }`.

## Struct versioning

Every input struct begins with `uint32_t struct_size` set to `sizeof(ThatStruct)`. libfits rejects unknown sizes.

## Threading

v0: use one `FitsRepo` per thread. Do not share handles across threads without external locking.

## Versioning

- `fits_api_version()` returns `(major << 16) | minor` for the **C struct layout**.
- JSON bodies include `protocol_version` (currently `1`) for payload shape.

Bump the API major version when any exported struct field order or meaning changes. Bump JSON `protocol_version` when request/response JSON changes.

## Build artifacts

`zig build` produces:

- `zig-out/lib/libfits.a` (static)
- `zig-out/lib/libfits.so` (shared)
- `zig-out/include/fits_core.h`, `libfits.h`

Optional CLI (legacy): `zig build -Dcli=true` installs the `fits` executable linked against the static library.
