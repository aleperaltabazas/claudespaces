# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
stack build

# Run all tests
stack test

# Run tests for a single module
stack test --test-arguments '--match Config'

# Run the CLI
stack exec claudespaces -- --help
stack exec claudespaces -- new ~/project
stack exec claudespaces -- list
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

Seven Haskell modules under `src/Claudespaces/` with `Cli.hs` as the integration point:

- **`Config.hs`** — loads `claudespaces.yml` from CWD and global config; raises error if both `image` and `dockerfile` keys are present
- **`Workspaces.hs`** — JSON state CRUD at `~/.claudespaces/workspaces.json`; migrates automatically from `sessions.json` on first load
- **`Image.hs`** — resolves a Docker image with `claude` pre-installed; builds a `claudespaces-base:<tag>` intermediate layer via `docker build`, skipping if already cached
- **`Container.hs`** — Docker CLI shell-outs; `buildMounts` is a pure function computing mount lists; `createContainer` calls `docker create`; `attachContainer` uses `docker exec -it` with TTY passthrough
- **`HostConfig.hs`** — loads `~/.config/claudespaces/claudespaces.yaml`; merges built-in operations (e.g. `notify`) with user-defined `host_bridge.operations`; writes `~/.claudespaces/shims.json`
- **`HostServer.hs`** — Scotty HTTP server on `0.0.0.0:<port>` (default 7731); handles `POST /run`; executes ops synchronously or fire-and-forget; spawned as a background process, killed when last workspace stops
- **`Cli.hs`** — optparse-applicative app with subcommands: `new`, `start`, `stop`, `remove`/`rm`, `list`/`ls`

### Key design decisions

**Workspace lifecycle:** `status` is set to `"running"` before `attachContainer` and back to `"stopped"` in a `finally` block — this survives exceptions and `UserInterrupt`. Auto-heal on startup detects containers that are no longer running (reboot, crash) and marks their workspaces stopped. Multiple workspaces for the same dir-set are valid. Names are unique across all workspaces.

**Mount strategy:** User dirs mount at `/workspace/<basename>` (rw); `~/.claude` paths mount at `/claudespaces/host/...` (ro) if they exist on the host. Basename collision across user dirs raises an error before any container is created.

**Host bridge:** Containers communicate with the host via a local HTTP server. `claudespaces-host` (a Python stdlib script bind-mounted at `/claudespaces/bin/claudespaces-host`) POSTs `{"op": "...", "args": ...}` to `http://host.docker.internal:<port>/run`. Operations with an `override` field get transparent shim scripts injected by `entrypoint.sh` at container start. The server binds to `0.0.0.0` so Docker bridge connections work; Linux requires `extra_hosts={"host.docker.internal": "host-gateway"}`.

**Docker interaction:** All Docker operations use CLI shell-outs (`docker build`, `docker create`, `docker exec`, etc.) with `--format json` for structured output where needed. No Docker SDK dependency.

**Testing:** Pure function tests via Hspec + Hedgehog. All Docker calls are in thin IO wrappers that are not tested. Workspace tests use a temp directory for state files.
