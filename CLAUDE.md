# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All commands use the project's virtual environment at `.venv/`.

```bash
# Install dependencies (first time)
pip install -e ".[dev]"

# Run all tests
.venv/bin/pytest

# Run a single test file
.venv/bin/pytest tests/test_workspaces.py -v

# Run a single test
.venv/bin/pytest tests/test_cli.py::test_new_creates_workspace -v

# Run the CLI (after install)
.venv/bin/claudespaces --help
```

## Task Management

This project tracks work with the `backlog` CLI. Never move task files manually with `mv` or git — always use the CLI.

### Task workflow

When starting any piece of work:

1. **Find or create a task** — search the backlog column for a matching task.
   - Clear match: pick it.
   - Uncertain match: ask the user to confirm before proceeding.
   - No match: create a new task with `backlog create`.
2. **Move to WIP** when you begin work: `backlog move <slug> --to wip`.
3. **Move to done** when the work is complete: `backlog move <slug> --to done`.

## Architecture

Seven focused modules with `cli.py` as the only integration point:

- **`config.py`** — loads `claudespaces.yml` from CWD; raises `ValueError` if both `image` and `dockerfile` keys are present
- **`workspaces.py`** — JSON state CRUD at `~/.claudespaces/workspaces.json`; `STATE_FILE` is a module-level constant that tests monkeypatch; migrates automatically from `sessions.json` on first load
- **`image.py`** — resolves a Docker image with `claude` pre-installed; always builds a `claudespaces-base:<tag>` intermediate layer, skipping if already cached locally
- **`container.py`** — Docker SDK wrapper; `create_container` builds mount lists and creates (but does not start) a container; `attach_container` uses `subprocess` for a real TTY; mounts `shims.json` and `claudespaces-host`; sets `host.docker.internal` via `extra_hosts`
- **`host_config.py`** — loads `~/.claudespaces/config.yml`; merges built-in operations (e.g. `notify`) with user-defined `host_bridge.operations`; writes `~/.claudespaces/shims.json` (binary→op manifest for shim injection)
- **`host_server.py`** — stdlib HTTP server on `0.0.0.0:<port>` (default 7731); handles `POST /run`; executes ops synchronously or fire-and-forget; spawned as a background subprocess on first workspace start, killed when last workspace stops
- **`cli.py`** — Typer app with five subcommands: `new`, `start`, `stop`, `remove`, `list`; no bare-path routing

### Key design decisions

**Workspace lifecycle:** `status` is set to `"running"` before `attach_container` and back to `"stopped"` in a `try/finally` — this survives Python exceptions and `KeyboardInterrupt`. Auto-heal on startup detects containers that are no longer running (reboot, crash) and marks their workspaces stopped. Multiple workspaces for the same dir-set are valid. Names are unique across all workspaces.

**Mount strategy:** User dirs mount at `/workspace/<basename>` (rw); three `~/.claude` paths mount at `/claudespaces/host/...` (ro) if they exist on the host. Basename collision across user dirs raises `ValueError` before any container is created.

**Host bridge:** Containers communicate with the host via a local HTTP server. `claudespaces-host` (a Python stdlib script bind-mounted at `/claudespaces/bin/claudespaces-host`) POSTs `{"op": "...", "args": ...}` to `http://host.docker.internal:<port>/run`. Operations with an `override` field get transparent shim scripts injected by `entrypoint.sh` at container start (e.g. `notify-send` → `claudespaces-host notify "$@"`). The server binds to `0.0.0.0` so Docker bridge connections work; Linux requires `extra_hosts={"host.docker.internal": "host-gateway"}`.

**Testing:** All Docker calls are mocked — no daemon required. Workspace tests monkeypatch `STATE_FILE` to `tmp_path`. CLI tests patch at the `claudespaces.cli.*` module boundary (e.g. `claudespaces.cli.docker`, `claudespaces.cli.workspaces`, `claudespaces.cli.host_server`, `claudespaces.cli.host_config`).
