# fits links (registry + `relations/links.jsonc`)

`fits` models **directed links** between **issued node ids**. A link instance is a **graph object** distinct from a node: it points **from** an `out` node id **to** an `in` node id, and is classified by a **link type** registered in the machine-owned registry.

## Creating link instances

`fits new link <LINK_TYPE> <IN_ID> <OUT_ID>` allocates the next `{LINK_TYPE}-{n}` id, appends `{ "link_type": …, "out": OUT_ID, "in": IN_ID }` to `relations/links.jsonc`, updates the registry counter, creates `relations/{LINK_TYPE}-{n}/` when `[link_types.<LINK_TYPE>] create_folder = true` in `.fits/fits_config.toml`, and rejects unknown link types or node ids whose prefixes do not match the registered **in** / **out** node types for `LINK_TYPE`. Node ids must be canonical (`{PREFIX}-{digits}` only) and issued/not tombstoned. Multiple rows may share the same `(link_type, out, in)` triple.

## Direction and CLI order

- **Semantics:** `out` → `in` (the `out` endpoint is the source of the edge; the `in` endpoint is the target).
- **Registration:** `fits register link-type <LINK_TYPE> <IN_NODE_TYPE> <OUT_NODE_TYPE>`  
  So the first node-type prefix after `LINK_TYPE` is the **in** endpoint’s prefix, and the second is the **out** endpoint’s prefix.

## Files and ownership

| Location | Role |
|----------|------|
| `.fits/registry.json` | Machine-owned. Declares node-type prefixes (JSON `obj_prefix`) and **link types** (counters + tombstones). **Do not edit by hand.** |
| `.fits/fits_config.toml` | Human-editable defaults: `[obj_types.PREFIX]` and `[link_types.NAME]` with `create_folder = true/false`. |
| `relations/links.jsonc` | Human-editable **index** of link instances (JSON with comments). Validated by `fits validate` after stripping comments. |
| `relations/<link-id>/` | Optional payload directory when `create_folder` is enabled for that link type (or set via `--create-folder` at registration). |

## Link instance ids

Link rows use ids shaped like `{LINK_TYPE}-{n}` (e.g. `implements-3`), with `n` allocated from the per–link-type counter in `.fits/registry.json`, parallel to node-type prefixes.

Node ids and link type names **must not overlap** so commands like `fits rm` can disambiguate `REQ-3` from `implements-3`.

## `relations/links.jsonc`

- **Format:** JSONC — `fits` accepts a **minimal** subset: line comments `//` and block comments `/* */` **outside** JSON strings. (`#` is not stripped.)
- **Canonical JSON** (after stripping) must conform to [schemas/links.schema.json](../schemas/links.schema.json).
- **Semantic checks** (during `fits validate`): `link_type` must be registered; `out` / `in` must be issued, non-tombstoned node ids whose prefixes match the registry row for that link type; link id must be issued and not tombstoned.

Removing a link with `fits rm` **tombstones** the numeric id in the registry, **removes the row** from `relations/links.jsonc`, and deletes `relations/<id>/` when present.

## `fits validate` and graph edges

Validation loads the links index, builds **graph edges** (`out` → `in`, tagged with `link_type`), and reports problems such as endpoints missing from loaded node bundles.

## Related documentation

- [Registry (node types + link types)](fits_registry.md) — `.fits/registry.json` fields and load behavior.
- [Registry JSON Schema](../schemas/registry.schema.json)
- [Links JSON Schema](../schemas/links.schema.json)
