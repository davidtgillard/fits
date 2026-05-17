# fits registry (`.fits/registry.json`)

The registry records **node types** (abstract and concrete), **link types** (endpoint type names plus counters), and which numeric instance ids have been issued or tombstoned. `fits` commands read and update `.fits/registry.json`; **do not edit it by hand**.

For how link instances are stored and edited, see [fits links](fits_links.md).

## Schema

The on-disk shape is defined by [schemas/registry.schema.json](../schemas/registry.schema.json) (JSON Schema draft 2020-12). The CLI validates every load against that contract and prints structural problems, for example:

```text
.fits/registry.json: at $.kind: must be "fits-registry", got "wrong"
.fits/registry.json: at node_types[0].next: must be an integer >= 1, got 0
```

Unknown properties are rejected (`additionalProperties: false` at each object level).

## Document envelope

Every registry file is a single JSON object:

| Field | Value |
|-------|-------|
| `description` | Canonical notice (purpose and “do not edit by hand”; written by the CLI) |
| `version` | `1` |
| `kind` | `"fits-registry"` |
| `node_types` | array of abstract or concrete node type entries |
| `link_types` | optional array of link type entries (omitted or `[]` when empty) |

Example envelope:

```json
{
  "description": "Tracks registered node types (abstract and concrete), link types, numeric id counters, and tombstones. Do not edit by hand; use the fits CLI.",
  "version": 1,
  "kind": "fits-registry",
  "node_types": [],
  "link_types": []
}
```

## Node types

Node types are either **abstract** (uninstantiable, scaffolding only under `nodes/<type>/`) or **concrete** (instantiable via `{id_prefix}-{n}` under a type-scoped folder in `nodes/`).

## Repository layout (`nodes/`)

Type scaffolding and instances use the registry **`type`** name (not necessarily the id prefix):

| Kind | Folder |
|------|--------|
| Abstract `req` | `nodes/req/` |
| Concrete `sys` extending `req` | `nodes/req/sys/` (instances: `nodes/req/sys/SYS-1/`, etc.) |
| Standalone concrete `sw` | `nodes/sw/` |

`fits register node-type` creates the scaffolding directory. `fits new node` writes instances at the concrete type’s leaf folder.

### Abstract entry

```json
{ "type": "req", "abstract": true }
```

- `type`: registry name (ASCII letter, then letters, digits, or `_`).
- No `extends`, `id_prefix`, `next`, or `tombstones`.

Register with: `fits register node-type req --abstract`

### Concrete entry

```json
{
  "type": "sys",
  "extends": "req",
  "id_prefix": "sys",
  "next": 4,
  "tombstones": [
    { "n": 2, "git_commit": "a1b2c3d4e5f6789012345678901234567890abcd" },
    { "n": 3 }
  ]
}
```

- `type`: registry name for this concrete type (must be unique among all `type`, `id_prefix`, and `link_type` names).
- `extends`: optional; when present, must name an **abstract** parent (concrete cannot extend concrete). Omit for a standalone concrete type (`nodes/<type>/` only).
- `id_prefix`: optional; defaults to `type` when omitted. Used in instance ids (`sys-1`) and for `fits new node <ID_PREFIX>`.
- `next`: next numeric suffix to allocate (integer ≥ 1). Issued ids are `1 .. next-1`.
- `tombstones`: optional (may be omitted; treated as empty). Same shape as link type tombstones.

Register with: `fits register node-type sys --extends req`

With `--create-folder`, `fits` records `create_folder = true` under `[obj_types.<id_prefix>]` in `.fits/fits_config.toml`.

### Type names vs id prefixes

- **Abstract** types have only a `type` name (e.g. `req`). They are not valid arguments to `fits new node`.
- **Concrete** types have a `type` and an `id_prefix` (often the same string, e.g. `REQ`). `fits new node REQ` allocates `REQ-1`, `REQ-2`, …
- Multiple concrete types may **extend** the same abstract type (e.g. `sys` and `cus` both extend `req`), each with its own `id_prefix` and counter.

## Link type entries

```json
{
  "link_type": "traces",
  "in_type": "req",
  "out_type": "DOC",
  "next": 2
}
```

- `link_type`: name of the link relation (same character rules as type names; must not collide with any node `type`, `id_prefix`, or other `link_type`).
- `in_type` / `out_type`: registered **type names** (abstract or concrete), not id prefixes. Instances link **from** the `out` node **to** the `in` node (see [fits_links.md](fits_links.md)).
- Endpoint validation resolves types: an abstract endpoint accepts any concrete node whose `extends` chain includes that abstract; a concrete endpoint requires the node’s concrete `type` (and matching `id_prefix` on the instance id).
- `next` / `tombstones`: same interpretation as for concrete node types.

Register with: `fits register link-type traces req DOC` (type names, not id prefixes).

## Load-time behavior (beyond JSON Schema)

- **Missing file**: treated as an empty registry (no node types).
- **Duplicate concrete rows** for the same `type`: merged; `next` becomes the maximum of the duplicates. Tombstones are merged with a “richer wins” rule when both rows tombstone the same `n`.
- **Semantic checks after structure**: `extends` must reference an existing abstract type; global uniqueness of `type`, all `id_prefix` values, and `link_type` names; allocation and tombstoning reject abstract types and unknown id prefixes.

## Rename and remove

### `fits register rename-type`

- **Abstract** rename: updates the abstract `type`, rewrites `extends` on all concrete children, and rewrites `in_type` / `out_type` on link types that referenced the old name. Renames the `nodes/<old>/` tree to `nodes/<new>/`.
- **Concrete** rename: updates the registry `type` and link endpoint type strings. When `id_prefix` equals the old `type`, `id_prefix` and instance basenames under the type folder are renamed together; when `id_prefix` differs from `type`, only registry and link endpoint strings change (files keep their existing ids). Renames the concrete type’s leaf folder under `nodes/`.

### `fits register rm`

- **Concrete** node type: same rules as before (instances, optional `--force`, `--cascade` for dangling links).
- **Abstract** node type: without children, removal is like an empty type. With concrete children or link types referencing the abstract name, removal requires `--force --cascade`, which removes child concrete types (and their instances), link types that reference the abstract name, dangling link rows for child id prefixes, then the abstract entry.
