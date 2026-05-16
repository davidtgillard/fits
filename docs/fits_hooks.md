# JSON validation hooks

Optional subprocess hooks can run after built-in structural validators during `fits validate`. They **read only JSON** on stdin and **write only JSON** on stdout. The fits host performs all filesystem and git access.

## Protocol

- **Version:** JSON schemas [`schemas/hooks_request.schema.json`](../schemas/hooks_request.schema.json) and [`schemas/hooks_response.schema.json`](../schemas/hooks_response.schema.json); domain constant `protocol_version = 1` in code.
- **Transport:** One batch per hook kind per validate run: an **objects** hook (optional) and a **links** hook (optional). The request includes a **bounded subgraph** of the repo graph (see schemas), not the full graph.
- **Extension point:** Schemas and docs reserve `extension_graph_api` for a future host-side graph query API (in-process or stdio RPC). Not available in the first delivery.

## Configuration (`.fits/hooks.toml`)

Create `.fits/hooks.toml` next to `fits_config.toml`. Example:

```toml
enabled = true
objects_command = ["my-hook", "objects"]
links_command = ["my-hook", "links"]
max_request_bytes = 33554432
timeout_secs = 120
```

- **`enabled`:** Hooks run only if this is `true` **and** you pass **`--hooks`** on the CLI.
- **`objects_command` / `links_command`:** JSON-array lines (same format as JSON array literals): full argv; first element is the executable.
- **`max_request_bytes`:** Rejects oversized request bodies before spawning (default 32 MiB).
- **`timeout_secs`:** Wall-clock I/O timeout for the child (`0` = host default / no bound).

## CLI

```sh
fits validate --hooks
fits validate --hooks --hooks-full
fits validate --hooks --no-hooks-incremental
```

- **`--hooks`:** Allow hooks to run when configured and enabled.
- **`--hooks-full`:** Ignore incremental optimization: every object/link row is considered for hook payloads (still subject to `max_request_bytes`).
- **`--no-hooks-incremental`:** Disable fingerprint-based skipping (same as a full refresh for the cache).

## Incremental behavior

When incremental mode is on (`--hooks` without `--hooks-full` or `--no-hooks-incremental`):

1. **Fingerprints** (Wyhash over canonical object bytes and link row fields) are stored in the LatticeDB cache under keys `hooks:obj:<argv-hash>:<id>` and `hooks:link:...`. If the fingerprint matches the last successful run for that id, the entity is skipped for that hook.
2. **Git narrowing** (when `.git` exists and `git diff HEAD --name-only` succeeds): only paths that appear in the diff are eligible. Object ids are taken from paths under `objects/<id>/`; link rows are filtered when `relations/links.jsonc` changes or paths under `relations/<link-id>/` change. If git is missing or the command fails, hooks fall back to fingerprint-only narrowing.

After a hook exits successfully (`0`), fingerprints for the entities in that batch are updated.

## Response mapping

Hook stdout must be JSON matching `hooks_response.schema.json`. Invalid rows and protocol errors are turned into [`Finding`](../src/domain/validation.zig) records (for example `hook.io`, hook-specific codes). Nonzero exit status produces an error-level finding with stderr text.

## Failure modes

- **Timeout / I/O:** Surfaced as host findings; stderr may be truncated.
- **Malformed JSON:** Parse errors become findings; validate still completes.
- **Request too large:** No subprocess run; a single finding describes the limit.
