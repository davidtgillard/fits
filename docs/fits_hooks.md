# JSON validation hooks

Optional subprocess hooks can run after built-in structural validators during `fits validate`. They **read only JSON** on stdin and **write only JSON** on stdout. The fits host performs all filesystem and git access.

## Protocol

- **Version:** JSON schemas [`schemas/hooks_request.schema.json`](../schemas/hooks_request.schema.json) and [`schemas/hooks_response.schema.json`](../schemas/hooks_response.schema.json); domain constant `protocol_version` in [`hook_protocol.zig`](../src/domain/hook_protocol.zig) matches the schema `const`.
- **Transport:** One batch per hook kind per validate run: a **nodes** hook (optional) and a **links** hook (optional). The request includes a **bounded subgraph** of the repo graph (see schemas), not the full graph.
- **Terminology:** A graph **object** is either a **node** (dataset instance under type-scoped `nodes/…`) or a **link** (row in `links/links.jsonc`). The nodes hook validates node payloads; the links hook validates link rows.
- **Extension point:** Schemas and docs reserve `extension_graph_api` for a future host-side graph query API (in-process or stdio RPC). Not available in the first delivery.

## Configuration (`.fits/hooks.toml`)

Create `.fits/hooks.toml` next to `fits_config.toml`. Example:

```toml
enabled = true
nodes_command = ["my-hook", "nodes"]
links_command = ["my-hook", "links"]
max_request_bytes = 33554432
timeout_secs = 120
```

- **`enabled`:** When `true`, hooks run on every `fits validate` (no separate CLI flag).
- **`nodes_command` / `links_command`:** JSON-array lines (same format as JSON array literals): full argv; first element is the executable.
- **`objects_command`:** Alias for **`nodes_command`** when `nodes_command` is omitted (same argv semantics).
- **`max_request_bytes`:** Rejects oversized request bodies before spawning (default 32 MiB).
- **`timeout_secs`:** Wall-clock I/O timeout for the child (`0` = host default / no bound).

## CLI

```sh
fits validate
fits validate --dry-run
fits validate --hooks-full-graph
```

- **`--dry-run`:** Run validation and hooks as usual but do not write hook fingerprint entries to the fits cache.
- **`--hooks-full-graph`:** Include every node and link in hook payloads; skip git narrowing and fingerprint-based skipping (still subject to `max_request_bytes`).

## Inspecting the graph

`fits output-graph` prints the hook-protocol `graph` object (nodes + edges) for the full repo snapshot to stdout—the same structural view hooks receive under full-graph scope, without `work` file payloads. Use `--pretty-print` for indented JSON.

## Incremental behavior

When incremental mode is on (default `fits validate`, without `--hooks-full-graph`):

1. **Fingerprints** (Wyhash over canonical node bundle bytes and link row fields) are stored in `.fits/cache/` under keys `hooks:node:<argv-hash>:<id>` and `hooks:link:...`. If the fingerprint matches the last successful run for that id, the entity is skipped for that hook.
2. **Git narrowing** (when `.git` exists and `git diff HEAD --name-only` succeeds): only paths that appear in the diff are eligible. Node ids are taken from path segments under `nodes/…` that match `{ID_PREFIX}-{n}`; link rows are filtered when `links/links.jsonc` changes or paths under `links/<link-type>/<link-id>/` change. If git is missing or the command fails, hooks fall back to fingerprint-only narrowing.

After a hook exits successfully (`0`), fingerprints for the entities in that batch are updated.

## `fits rebuild-cache`

```sh
fits rebuild-cache
```

Deletes all hook fingerprint cache entries (`hooks:*`), then runs hooks on the full graph (same scope as `fits validate --hooks-full-graph`) and persists new fingerprints. Built-in validators are not run. The update-check key (`update:last_check`) is left unchanged. When hooks are disabled, only the clear step runs.

## Response mapping

Hook stdout must be JSON matching `hooks_response.schema.json`. Invalid rows and protocol errors are turned into [`Finding`](../src/domain/validation.zig) records (for example `hook.io`, hook-specific codes). Nonzero exit status produces an error-level finding with stderr text.

## Failure modes

- **Timeout / I/O:** Surfaced as host findings; stderr may be truncated.
- **Malformed JSON:** Parse errors become findings; validate still completes.
- **Request too large:** No subprocess run; a single finding describes the limit.
