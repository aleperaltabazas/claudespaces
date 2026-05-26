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
.venv/bin/pytest tests/test_sessions.py -v

# Run a single test
.venv/bin/pytest tests/test_cli.py::test_first_run_no_sessions_creates_container -v

# Run the CLI (after install)
.venv/bin/claudespaces --help
```

## Architecture

Five focused modules with `cli.py` as the only integration point:

- **`config.py`** — loads `claudespaces.yml` from CWD; raises `ValueError` if both `image` and `dockerfile` keys are present
- **`sessions.py`** — JSON state CRUD at `~/.claudespaces/sessions.json`; `STATE_FILE` is a module-level constant that tests monkeypatch
- **`image.py`** — resolves a Docker image with `claude` pre-installed; always builds a `claudespaces-base:<tag>` intermediate layer, skipping if already cached locally
- **`container.py`** — Docker SDK wrapper; `create_container` builds mount lists and creates (but does not start) a container; `attach_container` uses `subprocess` for a real TTY
- **`cli.py`** — Typer app with `_PathAwareGroup` (a `TyperGroup` subclass) that routes bare directory paths to the callback instead of treating them as subcommand names; the main entry point is the callback, not a subcommand

### Key design decisions

**Typer routing fix:** Typer/Click treats the first positional arg as a potential subcommand name. `_PathAwareGroup.invoke` checks `ctx._protected_args[0]` against registered command names and moves it back to `ctx.args` if it's not a known command — this is how `claudespaces ~/proj` and `claudespaces list` coexist.

**Session lifecycle:** One session per unique sorted dir-set is enforced. On startup, `deduplicate_sessions` removes extras (keeping the most recently used) and returns stale container IDs for cleanup. Then `heal_running_sessions` marks sessions stopped if their container is no longer running (reboot, crash). `status` is set to `"running"` before `attach_container` and back to `"stopped"` in a `try/finally` — this survives Python exceptions and `KeyboardInterrupt`. If a session already exists for the requested dirs, it is auto-attached without any prompt; otherwise a new container and session are created.

**Mount strategy:** User dirs mount at `/workspace/<basename>` (rw); five `~/.claude` paths mount at `/root/.claude/...` (ro) if they exist on the host. Basename collision across user dirs raises `ValueError` before any container is created.

**Testing:** All Docker calls are mocked — no daemon required. Sessions tests monkeypatch `STATE_FILE` to `tmp_path`. CLI tests patch at the `claudespaces.cli.*` module boundary (e.g. `claudespaces.cli.docker`, `claudespaces.cli.sessions`).
