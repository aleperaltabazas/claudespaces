# claudespaces — Design

**Date:** 2026-05-18  
**Status:** Approved

## Overview

`claudespaces` is a Python CLI tool that launches persistent Docker containers running interactive Claude Code (`claude`) sessions. Users pass one or more local directories; those directories are mounted into the container alongside a curated subset of `~/.claude` config. Containers are persistent (stopped/restarted, never auto-removed) so tools installed by Claude inside the container survive between sessions.

## Project Structure

```
claudespaces/
├── pyproject.toml
├── claudespaces/
│   ├── __init__.py
│   ├── cli.py          # Typer app, entry point, command routing
│   ├── sessions.py     # session state CRUD (~/.claudespaces/sessions.json)
│   ├── container.py    # Docker SDK: create/start/stop/exec/remove
│   ├── image.py        # image resolution: named image, dockerfile build, default
│   └── config.py       # claudespaces.yml loader
└── tests/
    ├── test_sessions.py
    ├── test_image.py
    ├── test_container.py
    └── test_cli.py
```

## CLI Interface

```
claudespaces [DIRS...]                    # main entry point
claudespaces [DIRS...] --image NAME       # use a specific Docker image
claudespaces [DIRS...] --dockerfile PATH  # build image from Dockerfile
claudespaces list                         # list all sessions
claudespaces stop SESSION_ID              # stop a running container
claudespaces remove SESSION_ID            # destroy container + delete session record
```

The app uses a single `typer.Typer()` instance. The main entrypoint is the **app callback** (`invoke_without_command=True`); subcommands are registered normally. `ctx.invoked_subcommand` guards the callback from running when a subcommand is used.

## Module Responsibilities

### `config.py`
Loads `claudespaces.yml` from CWD. Returns a dict with any subset of `image`, `dockerfile`, `directories`. Raises `ValueError` if both `image` and `dockerfile` are present. CLI flags override config values; directories are merged (union, deduplicated, sorted).

### `sessions.py`
State file: `~/.claudespaces/sessions.json` (JSON array, created on first write).

Schema per record:
- `id`: 8-char hex (`secrets.token_hex(4)`)
- `name`: auto-generated `<adjective>-<noun>` from hardcoded 50×50 wordlist, unique within file
- `dirs`: sorted list of absolute expanded paths
- `container_id`, `image`, `status` (`"running"` | `"stopped"`)
- `created_at`, `last_used_at`: ISO 8601 UTC

All reads/writes are atomic: read whole file → mutate in memory → write back.

Key functions: `get_sessions_for_dirs`, `get_session_by_id`, `all_sessions`, `save_session`, `update_session`, `remove_session`, `heal_running_sessions`, `generate_name`.

### `image.py`
`resolve_image(image, dockerfile, docker_client) -> str`

1. Determine base: dockerfile → build it; `image` → use as-is; default → `ubuntu:24.04`.
2. Derive intermediate tag: `claudespaces-base:<base>` (`:` and `/` → `-`).
3. If tag exists locally (`images.get` succeeds), return it immediately (cache hit).
4. Otherwise write a temp Dockerfile and build:
   ```dockerfile
   FROM <base_image>
   RUN apt-get update && apt-get install -y curl && \
       curl -fsSL https://claude.ai/install.sh | sh
   ```
5. Return the intermediate tag.

### `container.py`
- `get_running_container_ids(docker_client) -> set[str]`
- `create_container(docker_client, image, dirs, claude_dir) -> str` — creates but does not start; raises `ValueError` on basename collision; skips missing `~/.claude` paths
- `attach_container(container_id) -> int` — `subprocess ["docker", "start", "-ai", container_id]`
- `stop_container(docker_client, container_id)`
- `remove_container(docker_client, container_id)` — silently ignores `NotFound`

Mounts: user dirs → `/workspace/<basename>` (rw); `~/.claude` subset → `/root/.claude/...` (ro, if exists).

Container settings: `tty=True`, `stdin_open=True`, workdir `/workspace`, cmd `["claude"]`.

### `cli.py`

**Main flow (`claudespaces [DIRS...]`):**
1. Pre-flight: verify Docker reachable; resolve/validate dirs; resolve image; warn if credentials missing.
2. Auto-heal: get running container IDs → mark stale "running" sessions as "stopped".
3. Session selector: if no sessions → `action="new"`; else show `questionary.select` with running sessions disabled.
4. Launch:
   - New: create container → save session (status=running) → attach → mark stopped in `finally`.
   - Resume: mark running → `docker start -ai` → mark stopped in `finally`.

**Error handling:**

| Situation | Behaviour |
|-----------|-----------|
| Docker not running | Print error, exit 1 |
| Directory not found / not a dir | Print error, exit 1 |
| Basename collision | Print error, exit 1 |
| `--dockerfile` path missing | Print error, exit 1 |
| `image` + `dockerfile` in config | Print error, exit 1 |
| `~/.claude/.credentials.json` missing | Print warning, continue |
| Session ID not found | Print error, exit 1 |
| No dirs + no `claudespaces.yml` | Print usage error, exit 1 |
| User cancels selector | Exit 0 |
| Python exception during attach | `finally` marks session stopped |

## Testing Strategy

All Docker calls mocked — no daemon required. Tests written before implementation (TDD).

- `test_sessions.py` — CRUD, heal, name generation
- `test_image.py` — cache hit/miss, dockerfile missing, tag derivation
- `test_container.py` — basename collision, mount logic, running IDs
- `test_cli.py` — full flow via `typer.testing.CliRunner`, all error paths
