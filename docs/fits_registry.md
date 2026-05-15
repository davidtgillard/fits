# fits registry (`.fits/registry.json`)

The registry records which object type prefixes exist, which **link types** exist between those prefixes, and which numeric instance ids have been issued or tombstoned for each. `fits` commands read and update `.fits/registry.json`; **do not edit it by hand**.

For how link instances are stored and edited, see [fits links](fits_links.md).

## Schema

The on-disk shape is defined by [schemas/registry.schema.json](../schemas/registry.schema.json) (JSON Schema draft 2020-12). The CLI validates every load against that contract and prints all structural problems, for example:

```text
.fits/registry.json: at $.kind: must be "fits-registry-v1", got "wrong"
.fits/registry.json: at prefixes[0].next: must be an integer >= 1, got 0
```

Unknown properties are rejected (`additionalProperties: false` at each object level).

## Document envelope

Every registry file is a single JSON object:

| Field | Value |
|-------|-------|
| `description` | Canonical notice (purpose and “do not edit by hand”; written by the CLI) |
| `version` | `1` |
| `kind` | `"fits-registry-v1"` |
| `prefixes` | array of object prefix entries |
| `link_types` | optional array of link type entries (omitted or `[]` in older repos) |

Example envelope:

```json
{
  "description": "Tracks registered object type prefixes, numeric id counters, and tombstones. Do not edit by hand; use the fits CLI.",
  "version": 1,
  "kind": "fits-registry-v1",
  "prefixes": [],
  "link_types": []
}
```

## Link type entries

```json
{
  "link_type": "implements",
  "in_obj_prefix": "REQ",
  "out_obj_prefix": "DOC",
  "next": 2
}
```

- `link_type`: name of the link relation (same character rules as object prefixes; must not collide with any `obj_prefix`).
- `in_obj_prefix` / `out_obj_prefix`: registered object prefixes. Instances link **from** `out` objects **to** `in` objects (see [fits_links.md](fits_links.md)).
- `next`: next numeric suffix for this link type (same interpretation as `prefixes[].next`).
- `tombstones`: optional, same shape as for object prefixes.

## Prefix entries

```json
{
  "obj_prefix": "REQ",
  "next": 4,
  "tombstones": [
    { "n": 2, "git_commit": "a1b2c3d4e5f6789012345678901234567890abcd" },
    { "n": 3 }
  ]
}
```

- `obj_prefix`: object type prefix (ASCII letter, then letters, digits, or `_`).
- `next`: next numeric suffix to allocate (integer ≥ 1). Issued ids are `1 .. next-1`.
- `tombstones`: optional array (may be omitted; treated as empty). Each tombstone has required `n` (integer ≥ 1) and optional `git_commit` (40 hexadecimal characters). JSON `null` for `git_commit` is accepted when present (as emitted by the CLI writer).

## Load-time behavior (beyond JSON Schema)

- **Missing file**: treated as an empty registry (no prefixes).
- **Duplicate prefix rows**: multiple entries with the same `obj_prefix` are merged; `next` becomes the maximum of the duplicates. Tombstones are merged with a “richer wins” rule when both rows tombstone the same `n`.
- **Semantic checks after structure**: allocation and tombstoning in memory still enforce registered prefixes, duplicate tombstones, and git commit format when recording removals.

## Related files

- `.fits/tombstone_cache.json` — derived mirror for fast lookup; same tombstone ids, not a substitute for the registry.
