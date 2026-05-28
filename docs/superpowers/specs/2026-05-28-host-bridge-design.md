# Host Bridge Design

**Date:** 2026-05-28
**Status:** Draft

## Overview

Add a host bridge mechanism that allows claudespaces containers to invoke a configurable set of host-side operations. The motivating use case is desktop notifications: a Claude Code hook inside the container calls `notify-send`, which needs to reach the host desktop environment. The bridge is general-purpose — any host-side operation can be exposed, with optional transparent shim injection to make it invisible to in-container callers.

## Architecture

Four new pieces, plus changes to two existing modules:

- **`host_config.py`** — loads `~/.claudespaces/config.yml`, merges user-defined `host_bridge.operations` with built-in operations (`notify`). User config wins on conflict.
- **`host_server.py`** — a stdlib HTTP server listening on `localhost:<port>`. Handles `POST /run`, validates the operation against the allowed list, executes it synchronously or asynchronously, and returns the result.
- **`claudespaces-host`** — a small script installed in the container image. POSTs to `http://host.docker.internal:<port>/run` with the operation name and args. Mirrors exit code for sync ops.
- **Shim injection via `entrypoint.sh`** — at container start, reads a manifest file mounted from the host and writes shim scripts for any operation with an `override` field.
- **`cli.py`** — `start` checks if the server is already running on the configured port; spawns it as a background subprocess if not, storing the PID in `~/.claudespaces/host_bridge.pid`. `stop` kills the server if no other workspaces remain running.
- **`container.py`** — mounts the shim manifest (`~/.claudespaces/shims.json`) into the container at a well-known path; injects `CLAUDESPACES_HOST_PORT` env var so `claudespaces-host` knows which port to use.

## Config

Global config at `~/.claudespaces/config.yml`:

```yaml
host_bridge:
  port: 7731  # default if omitted
  operations:
    notify:
      command: "notify-send {summary} {body}"
      args: [summary, body]
      async: true
      override: notify-send  # optional — injects shim in container
```

Built-in operations ship as defaults in `host_config.py`. The `args` field defines the named parameter list for explicit CLI invocation. The `override` field names the in-container binary to replace with a shim.

## Data Flow

**Explicit call:**
```
claudespaces-host notify --summary "Done" --body "Tests passed"
  → POST /run {"op": "notify", "args": {"summary": "Done", "body": "Tests passed"}}
  → host validates op, executes command
  → async → detached, returns {"status": "ok"}
  → sync  → waits, returns {"stdout": "...", "stderr": "...", "exit_code": 0}
claudespaces-host exits with mirrored exit code
```

**Override (shim) call:**
```
notify-send "Done" "Tests passed"
  → shim: claudespaces-host notify "$@"
  → args passed verbatim to host command, no named-arg mapping
```

**Server lifecycle:**
```
claudespaces start → port 7731 free → spawn server, write PID to ~/.claudespaces/host_bridge.pid
claudespaces start (second workspace) → port in use → skip
claudespaces stop → 0 running workspaces remain → kill PID, remove pid file
claudespaces stop → other workspaces still running → leave server alive
```

## Shim Injection

`cli.py` writes `~/.claudespaces/shims.json` before starting the container — a flat map of binary name to operation name for every operation with an `override`:

```json
{"notify-send": "notify"}
```

`container.py` bind-mounts this file into the container at `/claudespaces/shims.json` (read-only). `entrypoint.sh` reads it at startup and for each entry:

1. If the original binary exists, rename it to `<name>.orig`.
2. Write a shim at the original path:
   ```sh
   #!/bin/sh
   claudespaces-host <op-name> "$@"
   ```
3. Make the shim executable.

If the original binary does not exist (common in headless containers), skip step 1 and just create the shim.

## Error Handling

| Situation | Behaviour |
|---|---|
| Op not in allowed list | Server returns 400 `{"error": "unknown operation"}`; `claudespaces-host` prints to stderr, exits 1 |
| Sync command fails | stdout/stderr/exit code returned as-is; `claudespaces-host` mirrors exit code |
| Async command fails | No propagation; host logs error to server's stderr |
| Server not running | `claudespaces-host` gets connection refused; prints "host bridge is not running", exits 1 |
| Port in use by something else | `claudespaces start` warns user and continues; bridge unavailable for that session |

## Testing

- **`test_host_config.py`** — config loading with/without `host_bridge` section; built-in `notify` always present; user config wins on conflict.
- **`test_host_server.py`** — valid op returns correct response; unknown op returns 400; async op returns immediately; sync op returns stdout/stderr/exit code.
- **`test_cli.py`** additions — `start` spawns server when port is free, skips when already in use; `stop` kills server when last workspace, leaves it when others remain.
- **`test_shims.py`** — manifest written by `cli.py` matches overrides in config; `entrypoint.sh` shim injection produces correct shim scripts.
