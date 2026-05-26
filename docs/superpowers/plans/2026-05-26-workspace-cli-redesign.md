# Workspace CLI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the implicit `claudespaces <dir>` entry point with explicit `new`/`start` commands, rename sessions→workspaces throughout, and key all management commands by name.

**Architecture:** A new `workspaces.py` module replaces `sessions.py` with `name` as the primary key; the full `cli.py` is rewritten to expose `new`, `start`, `stop`, `remove`, and `list` as named subcommands with no bare-path routing. The `_PathAwareGroup` hack and `deduplicate_sessions` logic are deleted; multiple workspaces per dir-set become valid.

**Tech Stack:** Python 3.11+, Typer, Docker SDK, pytest, pytest-mock

---

### Task 1: Write spec doc

**Files:**

- Create: `docs/superpowers/specs/2026-05-26-workspace-cli-redesign.md`

- [ ] **Step 1: Write the spec**

````markdown
# Workspace CLI Redesign

## Problem

The current CLI uses `claudespaces <dir>` as its entry point, which builds the image,
creates the container, and attaches in one shot. Users cannot prepare a workspace ahead
of time or give it a meaningful name without interactive prompting.

## Solution

Introduce explicit `new` and `start` commands. Provisioning and attaching are now
separate, deliberate steps. Terminology changes from "session" to "workspace" throughout.

## Commands

\`\`\`
claudespaces new [--named <name>] [--start] [--image <img>] [--dockerfile <path>] <dir...>
claudespaces start <name>
claudespaces stop <name>
claudespaces remove <name>
claudespaces list
\`\`\`

- **new**: builds the image (cached), creates the container in stopped state, saves the workspace.
  `--named` sets the name; omitted = auto-generated. `--start` attaches immediately after creation.
- **start**: attaches to a stopped workspace; errors if not found or already running.
- **stop / remove / list**: same behaviour as before, keyed by name instead of ID.

## Data Model

```json
{
  "name": "my-game",
  "dirs": ["/absolute/path/proj1"],
  "container_id": "sha256...",
  "image": "claudespaces-base:...",
  "created_at": "2026-05-26T...",
  "last_used_at": "2026-05-26T...",
  "status": "stopped"
}
```
````

State file: `~/.claudespaces/workspaces.json` (migrated from `sessions.json` on first load).

## Error Handling

| Situation                                  | Message                                  |
| ------------------------------------------ | ---------------------------------------- |
| `new --named <x>` and `<x>` already exists | `Workspace '<x>' already exists.`        |
| workspace not found                        | `Workspace '<name>' not found.`          |
| `start` — already running                  | `Workspace '<name>' is already running.` |
| `stop` — already stopped                   | no-op + message                          |
| Docker not reachable                       | existing message, unchanged              |

## Removed

- `claudespaces <dir>` bare-path entry point
- `_PathAwareGroup` routing hack
- `deduplicate_sessions` / one-session-per-dir enforcement
- Session `id` field (name is now the primary key)

````

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-05-26-workspace-cli-redesign.md
git commit -m "docs: add workspace CLI redesign spec"
````

---

### Task 2: Create `workspaces.py` (TDD)

**Files:**

- Create: `claudespaces/workspaces.py`
- Create: `tests/test_workspaces.py`

- [ ] **Step 1: Write failing tests**

Create `tests/test_workspaces.py`:

```python
import json
import pytest
from claudespaces import workspaces


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(workspaces, "STATE_FILE", tmp_path / "workspaces.json")


def _w(**kwargs):
    base = {
        "name": "bold-space",
        "dirs": ["/home/user/proj1"],
        "container_id": "container123",
        "image": "claudespaces-base:ubuntu-24.04",
        "created_at": "2026-05-26T10:00:00Z",
        "last_used_at": "2026-05-26T12:00:00Z",
        "status": "stopped",
    }
    return {**base, **kwargs}


def test_save_and_read_back():
    workspaces.save_workspace(_w())
    result = workspaces.all_workspaces()
    assert len(result) == 1
    assert result[0]["name"] == "bold-space"


def test_all_workspaces_returns_all():
    workspaces.save_workspace(_w(name="ws-a"))
    workspaces.save_workspace(_w(name="ws-b"))
    assert len(workspaces.all_workspaces()) == 2


def test_get_workspace_by_name_found():
    workspaces.save_workspace(_w(name="bold-space"))
    result = workspaces.get_workspace_by_name("bold-space")
    assert result is not None
    assert result["name"] == "bold-space"


def test_get_workspace_by_name_not_found():
    assert workspaces.get_workspace_by_name("nope") is None


def test_name_exists_true():
    workspaces.save_workspace(_w(name="bold-space"))
    assert workspaces.name_exists("bold-space") is True


def test_name_exists_false():
    assert workspaces.name_exists("nope") is False


def test_update_workspace_changes_fields():
    workspaces.save_workspace(_w(name="bold-space", status="running"))
    workspaces.update_workspace("bold-space", status="stopped")
    assert workspaces.get_workspace_by_name("bold-space")["status"] == "stopped"


def test_update_workspace_leaves_other_fields_intact():
    workspaces.save_workspace(_w(name="bold-space", status="running"))
    workspaces.update_workspace("bold-space", status="stopped")
    assert workspaces.get_workspace_by_name("bold-space")["dirs"] == ["/home/user/proj1"]


def test_remove_workspace_removes_correct_record():
    workspaces.save_workspace(_w(name="ws-a"))
    workspaces.save_workspace(_w(name="ws-b"))
    workspaces.remove_workspace("ws-a")
    remaining = workspaces.all_workspaces()
    assert len(remaining) == 1
    assert remaining[0]["name"] == "ws-b"


def test_heal_marks_stale_running_as_stopped():
    workspaces.save_workspace(_w(name="bold-space", status="running", container_id="c1"))
    workspaces.heal_running_workspaces(set())
    assert workspaces.get_workspace_by_name("bold-space")["status"] == "stopped"


def test_heal_leaves_actually_running_unchanged():
    workspaces.save_workspace(_w(name="bold-space", status="running", container_id="c1"))
    workspaces.heal_running_workspaces({"c1"})
    assert workspaces.get_workspace_by_name("bold-space")["status"] == "running"


def test_heal_leaves_stopped_workspaces_unchanged():
    workspaces.save_workspace(_w(name="bold-space", status="stopped", container_id="c1"))
    workspaces.heal_running_workspaces(set())
    assert workspaces.get_workspace_by_name("bold-space")["status"] == "stopped"


def test_heal_only_changes_stale_not_all():
    workspaces.save_workspace(_w(name="ws-a", status="running", container_id="c1"))
    workspaces.save_workspace(_w(name="ws-b", status="running", container_id="c2"))
    workspaces.heal_running_workspaces({"c2"})
    assert workspaces.get_workspace_by_name("ws-a")["status"] == "stopped"
    assert workspaces.get_workspace_by_name("ws-b")["status"] == "running"


def test_multiple_workspaces_same_dirs_allowed():
    workspaces.save_workspace(_w(name="ws-a", dirs=["/a"]))
    workspaces.save_workspace(_w(name="ws-b", dirs=["/a"]))
    assert len(workspaces.all_workspaces()) == 2


def test_generate_name_format():
    name = workspaces.generate_name(set())
    parts = name.split("-")
    assert len(parts) == 2
    assert parts[0] in workspaces.ADJECTIVES
    assert parts[1] in workspaces.NOUNS


def test_generate_name_avoids_collisions():
    all_names = {
        f"{adj}-{noun}"
        for adj in workspaces.ADJECTIVES
        for noun in workspaces.NOUNS
        if not (adj == workspaces.ADJECTIVES[0] and noun == workspaces.NOUNS[0])
    }
    name = workspaces.generate_name(all_names)
    assert name not in all_names
    assert name == f"{workspaces.ADJECTIVES[0]}-{workspaces.NOUNS[0]}"


def test_migrates_from_sessions_json(tmp_path, monkeypatch):
    # STATE_FILE is patched to tmp_path/workspaces.json by autouse fixture.
    # Migration looks for sessions.json in STATE_FILE.parent (= tmp_path).
    sessions_file = tmp_path / "sessions.json"
    sessions_file.write_text(json.dumps([{
        "id": "abc123",
        "name": "old-session",
        "dirs": ["/home/user/proj"],
        "container_id": "c1",
        "image": "img",
        "created_at": "2026-05-01T00:00:00Z",
        "last_used_at": "2026-05-01T00:00:00Z",
        "status": "stopped",
    }]))
    result = workspaces.all_workspaces()
    assert len(result) == 1
    assert result[0]["name"] == "old-session"
    assert "id" not in result[0]
    assert (tmp_path / "workspaces.json").exists()
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
.venv/bin/pytest tests/test_workspaces.py -v
```

Expected: `ModuleNotFoundError` or `ImportError` — `workspaces` module doesn't exist yet.

- [ ] **Step 3: Implement `workspaces.py`**

Create `claudespaces/workspaces.py`:

```python
import json
import random
from pathlib import Path

STATE_FILE = Path.home() / ".claudespaces" / "workspaces.json"

ADJECTIVES = [
    "bold", "calm", "dark", "deep", "fast", "free", "hard", "high",
    "kind", "last", "late", "long", "loud", "mild", "near", "next",
    "nice", "open", "pure", "rare", "real", "rich", "safe", "slim",
    "slow", "soft", "tall", "thin", "tiny", "vast", "warm", "wide",
    "wild", "wise", "blue", "cold", "cool", "dull", "fair", "firm",
    "flat", "full", "gray", "keen", "lazy", "lean", "live", "lost",
    "mad", "neat",
]

NOUNS = [
    "space", "orbit", "comet", "cloud", "creek", "delta", "drift",
    "dusk", "echo", "field", "flame", "flare", "flash", "flow",
    "forge", "frost", "glade", "gleam", "grove", "haven", "haze",
    "isle", "lake", "leap", "light", "lodge", "loom", "lunar",
    "marsh", "mist", "moon", "moss", "nova", "ocean", "peak",
    "plain", "prism", "pulse", "ridge", "rift", "river", "rock",
    "shade", "shore", "sky", "slope", "snow", "solar", "spark",
    "star", "stone",
]


def _load() -> list[dict]:
    if not STATE_FILE.exists():
        _migrate_from_sessions()
        if not STATE_FILE.exists():
            return []
    with open(STATE_FILE) as f:
        return json.load(f)


def _migrate_from_sessions() -> None:
    old = STATE_FILE.parent / "sessions.json"
    if not old.exists():
        return
    with open(old) as f:
        data = json.load(f)
    for w in data:
        w.pop("id", None)
    _save(data)


def _save(workspace_list: list[dict]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(workspace_list, f, indent=2)


def all_workspaces() -> list[dict]:
    return _load()


def get_workspace_by_name(name: str) -> dict | None:
    for w in _load():
        if w["name"] == name:
            return w
    return None


def name_exists(name: str) -> bool:
    return get_workspace_by_name(name) is not None


def save_workspace(workspace: dict) -> None:
    data = _load()
    data.append(workspace)
    _save(data)


def update_workspace(name: str, **fields) -> None:
    data = _load()
    for w in data:
        if w["name"] == name:
            w.update(fields)
    _save(data)


def remove_workspace(name: str) -> None:
    _save([w for w in _load() if w["name"] != name])


def heal_running_workspaces(running_container_ids: set[str]) -> None:
    data = _load()
    changed = False
    for w in data:
        if w["status"] == "running" and w["container_id"] not in running_container_ids:
            w["status"] = "stopped"
            changed = True
    if changed:
        _save(data)


def generate_name(existing_names: set[str]) -> str:
    for _ in range(10_000):
        name = f"{random.choice(ADJECTIVES)}-{random.choice(NOUNS)}"
        if name not in existing_names:
            return name
    raise RuntimeError("Could not generate a unique name after 10000 attempts")
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
.venv/bin/pytest tests/test_workspaces.py -v
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add claudespaces/workspaces.py tests/test_workspaces.py
git commit -m "feat: add workspaces module replacing sessions"
```

---

### Task 3: Rewrite `cli.py` and `test_cli.py` (TDD)

**Files:**

- Modify: `claudespaces/cli.py`
- Modify: `tests/test_cli.py`

- [ ] **Step 1: Replace `tests/test_cli.py` with new tests**

```python
import pytest
from unittest.mock import MagicMock
from typer.testing import CliRunner
from claudespaces.cli import app

runner = CliRunner()


@pytest.fixture
def mock_docker(mocker):
    client = MagicMock()
    mocker.patch("claudespaces.cli.docker.from_env", return_value=client)
    return client


@pytest.fixture
def mock_workspaces(mocker):
    m = mocker.patch("claudespaces.cli.workspaces")
    m.all_workspaces.return_value = []
    m.heal_running_workspaces.return_value = None
    m.generate_name.return_value = "bold-space"
    m.name_exists.return_value = False
    m.get_workspace_by_name.return_value = None
    return m


@pytest.fixture
def mock_container(mocker):
    m = mocker.patch("claudespaces.cli.container")
    m.get_running_container_ids.return_value = set()
    m.create_container.return_value = "container123"
    return m


@pytest.fixture
def mock_image(mocker):
    m = mocker.patch("claudespaces.cli.image")
    m.resolve_image.return_value = "claudespaces-base:ubuntu-24.04"
    return m


@pytest.fixture
def mock_config(mocker):
    m = mocker.patch("claudespaces.cli.config")
    m.load_config.return_value = {}
    return m


# --- new ---

def test_new_creates_workspace(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    result = runner.invoke(app, ["new", str(proj)])
    mock_container.create_container.assert_called_once()
    mock_workspaces.save_workspace.assert_called_once()
    assert result.exit_code == 0


def test_new_uses_provided_name(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    runner.invoke(app, ["new", "--named", "my-game", str(proj)])
    saved = mock_workspaces.save_workspace.call_args.args[0]
    assert saved["name"] == "my-game"


def test_new_generates_name_when_not_provided(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    runner.invoke(app, ["new", str(proj)])
    saved = mock_workspaces.save_workspace.call_args.args[0]
    assert saved["name"] == "bold-space"


def test_new_errors_when_name_already_exists(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    mock_workspaces.name_exists.return_value = True
    result = runner.invoke(app, ["new", "--named", "my-game", str(proj)])
    assert result.exit_code == 1
    assert "Workspace 'my-game' already exists." in result.output
    mock_container.create_container.assert_not_called()


def test_new_saves_workspace_as_stopped(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    runner.invoke(app, ["new", str(proj)])
    saved = mock_workspaces.save_workspace.call_args.args[0]
    assert saved["status"] == "stopped"


def test_new_with_start_attaches_after_create(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    result = runner.invoke(app, ["new", "--start", str(proj)])
    mock_container.attach_container.assert_called_once_with("container123")
    assert result.exit_code == 0


def test_new_with_start_sets_status_stopped_after_attach(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    runner.invoke(app, ["new", "--start", str(proj)])
    mock_container.stop_container.assert_called_once()
    update_calls = mock_workspaces.update_workspace.call_args_list
    assert any(call.kwargs.get("status") == "stopped" for call in update_calls)


def test_new_exits_1_when_docker_unreachable(tmp_path, mocker, mock_config):
    mocker.patch("claudespaces.cli.docker.from_env", side_effect=Exception("no docker"))
    proj = tmp_path / "proj"
    proj.mkdir()
    result = runner.invoke(app, ["new", str(proj)])
    assert result.exit_code == 1
    assert "Docker is not running" in result.output


def test_new_exits_1_when_directory_not_found(mock_docker, mock_config):
    result = runner.invoke(app, ["new", "/nonexistent/path/xyz"])
    assert result.exit_code == 1
    assert "Directory not found" in result.output


def test_new_exits_1_when_path_is_not_a_directory(mock_docker, mock_config, tmp_path):
    f = tmp_path / "file.txt"
    f.write_text("hello")
    result = runner.invoke(app, ["new", str(f)])
    assert result.exit_code == 1
    assert "Not a directory" in result.output


# --- start ---

def test_start_attaches_to_workspace(mock_docker, mock_workspaces, mock_container):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "stopped",
    }
    result = runner.invoke(app, ["start", "my-game"])
    mock_container.attach_container.assert_called_once_with("c1")
    assert result.exit_code == 0


def test_start_errors_when_workspace_not_found(mock_workspaces):
    mock_workspaces.get_workspace_by_name.return_value = None
    result = runner.invoke(app, ["start", "nope"])
    assert result.exit_code == 1
    assert "Workspace 'nope' not found." in result.output


def test_start_errors_when_already_running(mock_docker, mock_workspaces, mock_container):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "running",
    }
    result = runner.invoke(app, ["start", "my-game"])
    assert result.exit_code == 1
    assert "Workspace 'my-game' is already running." in result.output
    mock_container.attach_container.assert_not_called()


def test_start_sets_status_running_before_attach(mock_docker, mock_workspaces, mock_container):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "stopped",
    }
    runner.invoke(app, ["start", "my-game"])
    update_calls = mock_workspaces.update_workspace.call_args_list
    assert any(call.kwargs.get("status") == "running" for call in update_calls)


def test_start_sets_status_stopped_and_stops_container_after_attach(
    mock_docker, mock_workspaces, mock_container
):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "stopped",
    }
    runner.invoke(app, ["start", "my-game"])
    update_calls = mock_workspaces.update_workspace.call_args_list
    assert any(call.kwargs.get("status") == "stopped" for call in update_calls)
    mock_container.stop_container.assert_called_once()


def test_start_exits_1_when_docker_unreachable(mocker, mock_workspaces):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "stopped",
    }
    mocker.patch("claudespaces.cli.docker.from_env", side_effect=Exception("no docker"))
    result = runner.invoke(app, ["start", "my-game"])
    assert result.exit_code == 1
    assert "Docker is not running" in result.output


# --- stop ---

def test_stop_unknown_workspace_exits_1(mock_workspaces):
    mock_workspaces.get_workspace_by_name.return_value = None
    result = runner.invoke(app, ["stop", "nope"])
    assert result.exit_code == 1
    assert "Workspace 'nope' not found." in result.output


def test_stop_already_stopped_workspace(mock_docker, mock_workspaces):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "stopped",
    }
    result = runner.invoke(app, ["stop", "my-game"])
    assert result.exit_code == 0
    assert "already stopped" in result.output


def test_stop_running_workspace(mock_docker, mock_workspaces, mock_container):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "running",
    }
    result = runner.invoke(app, ["stop", "my-game"])
    assert result.exit_code == 0
    mock_container.stop_container.assert_called_once()
    mock_workspaces.update_workspace.assert_called_once_with("my-game", status="stopped")
    assert "Stopped workspace 'my-game'" in result.output


# --- remove ---

def test_remove_unknown_workspace_exits_1(mock_workspaces):
    mock_workspaces.get_workspace_by_name.return_value = None
    result = runner.invoke(app, ["remove", "nope"])
    assert result.exit_code == 1
    assert "Workspace 'nope' not found." in result.output


def test_remove_workspace(mock_docker, mock_workspaces, mock_container):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "stopped",
    }
    result = runner.invoke(app, ["remove", "my-game"])
    assert result.exit_code == 0
    mock_container.remove_container.assert_called_once()
    mock_workspaces.remove_workspace.assert_called_once_with("my-game")
    assert "Removed workspace 'my-game'" in result.output


def test_remove_when_container_already_gone(mock_docker, mock_workspaces, mock_container):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "stopped",
    }
    mock_container.remove_container.return_value = None  # NotFound swallowed by container.py
    result = runner.invoke(app, ["remove", "my-game"])
    assert result.exit_code == 0
    mock_workspaces.remove_workspace.assert_called_once_with("my-game")


# --- list ---

def test_list_no_workspaces(mock_workspaces):
    mock_workspaces.all_workspaces.return_value = []
    result = runner.invoke(app, ["list"])
    assert result.exit_code == 0
    assert "No workspaces found." in result.output


def test_list_with_workspaces(mock_workspaces):
    mock_workspaces.all_workspaces.return_value = [{
        "name": "bold-space",
        "dirs": ["/home/user/proj1"],
        "container_id": "c1",
        "status": "stopped",
        "last_used_at": "2026-05-26T14:32:00Z",
        "created_at": "2026-05-26T10:00:00Z",
        "image": "claudespaces-base:ubuntu-24.04",
    }]
    result = runner.invoke(app, ["list"])
    assert result.exit_code == 0
    assert "bold-space" in result.output
    assert "stopped" in result.output
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
.venv/bin/pytest tests/test_cli.py -v
```

Expected: most tests FAIL — `new` and `start` commands don't exist; `stop`/`remove`/`list` still use session API.

- [ ] **Step 3: Rewrite `cli.py`**

Replace the entire contents of `claudespaces/cli.py` with:

```python
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import docker
import typer

from claudespaces import config, container, image, workspaces

app = typer.Typer()


def _now_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@app.command()
def new(
    dirs: list[str] = typer.Argument(...),
    named: Optional[str] = typer.Option(None, "--named"),
    start: bool = typer.Option(False, "--start"),
    image_name: Optional[str] = typer.Option(None, "--image"),
    dockerfile: Optional[str] = typer.Option(None, "--dockerfile"),
) -> None:
    try:
        cfg = config.load_config()
    except ValueError as e:
        typer.echo(str(e))
        raise typer.Exit(1)

    if named is not None and workspaces.name_exists(named):
        typer.echo(f"Workspace '{named}' already exists.")
        raise typer.Exit(1)

    global_dockerfile = cfg.get("global_dockerfile")

    if image_name is None and dockerfile is None:
        image_name = cfg.get("image")
        dockerfile = cfg.get("dockerfile")

    cfg_dirs = [os.path.expanduser(d) for d in cfg.get("directories", [])]
    cli_dirs = [os.path.expanduser(d) for d in (dirs or [])]
    all_dirs = sorted(set(cfg_dirs + cli_dirs))

    if not all_dirs:
        if Path("claudespaces.yml").exists():
            all_dirs = [str(Path.cwd())]
        else:
            typer.echo("No directories specified. Usage: claudespaces new DIR [DIR...]")
            raise typer.Exit(1)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    resolved_dirs = []
    for d in all_dirs:
        abs_d = os.path.abspath(d)
        if not os.path.exists(abs_d):
            typer.echo(f"Directory not found: {abs_d}")
            raise typer.Exit(1)
        if not os.path.isdir(abs_d):
            typer.echo(f"Not a directory: {abs_d}")
            raise typer.Exit(1)
        resolved_dirs.append(abs_d)

    if global_dockerfile:
        global_dockerfile = os.path.abspath(os.path.expanduser(global_dockerfile))
    if dockerfile:
        dockerfile = os.path.abspath(os.path.expanduser(dockerfile))

    try:
        resolved_image = image.resolve_image(image_name, global_dockerfile, dockerfile, docker_client)
    except FileNotFoundError as e:
        typer.echo(str(e))
        raise typer.Exit(1)
    except docker.errors.BuildError as e:
        typer.echo(f"Docker build failed: {e}")
        for entry in e.build_log:
            if isinstance(entry, dict) and "stream" in entry:
                typer.echo(entry["stream"], nl=False)
        raise typer.Exit(1)

    running_ids = container.get_running_container_ids(docker_client)
    workspaces.heal_running_workspaces(running_ids)

    try:
        container_id = container.create_container(docker_client, resolved_image, resolved_dirs)
    except ValueError as e:
        typer.echo(str(e))
        raise typer.Exit(1)

    existing_names = {w["name"] for w in workspaces.all_workspaces()}
    name = named if named is not None else workspaces.generate_name(existing_names)

    workspace = {
        "name": name,
        "dirs": resolved_dirs,
        "container_id": container_id,
        "image": resolved_image,
        "created_at": _now_utc(),
        "last_used_at": _now_utc(),
        "status": "stopped",
    }
    workspaces.save_workspace(workspace)
    typer.echo(f"Created workspace '{name}'.")

    if start:
        workspaces.update_workspace(name, status="running")
        try:
            container.attach_container(container_id)
        except KeyboardInterrupt:
            pass
        finally:
            workspaces.update_workspace(name, status="stopped", last_used_at=_now_utc())
            container.stop_container(docker_client, container_id)


@app.command()
def start(name: str) -> None:
    workspace = workspaces.get_workspace_by_name(name)
    if workspace is None:
        typer.echo(f"Workspace '{name}' not found.")
        raise typer.Exit(1)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    running_ids = container.get_running_container_ids(docker_client)
    workspaces.heal_running_workspaces(running_ids)

    workspace = workspaces.get_workspace_by_name(name)
    if workspace["status"] == "running":
        typer.echo(f"Workspace '{name}' is already running.")
        raise typer.Exit(1)

    workspaces.update_workspace(name, status="running")
    try:
        container.attach_container(workspace["container_id"])
    except KeyboardInterrupt:
        pass
    finally:
        workspaces.update_workspace(name, status="stopped", last_used_at=_now_utc())
        container.stop_container(docker_client, workspace["container_id"])


@app.command()
def stop(name: str) -> None:
    workspace = workspaces.get_workspace_by_name(name)
    if workspace is None:
        typer.echo(f"Workspace '{name}' not found.")
        raise typer.Exit(1)

    if workspace["status"] == "stopped":
        typer.echo(f"Workspace '{name}' is already stopped.")
        raise typer.Exit(0)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    try:
        container.stop_container(docker_client, workspace["container_id"])
    except Exception as e:
        typer.echo(f"Failed to stop container: {e}")
        raise typer.Exit(1)
    workspaces.update_workspace(name, status="stopped")
    typer.echo(f"Stopped workspace '{name}'.")


@app.command()
def remove(name: str) -> None:
    workspace = workspaces.get_workspace_by_name(name)
    if workspace is None:
        typer.echo(f"Workspace '{name}' not found.")
        raise typer.Exit(1)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    try:
        container.remove_container(docker_client, workspace["container_id"])
    except Exception as e:
        typer.echo(f"Failed to remove container: {e}")
        raise typer.Exit(1)
    workspaces.remove_workspace(name)
    typer.echo(f"Removed workspace '{name}'.")


@app.command()
def list() -> None:
    all_ws = workspaces.all_workspaces()
    if not all_ws:
        typer.echo("No workspaces found.")
        raise typer.Exit(0)

    home = str(Path.home())

    def collapse(path: str) -> str:
        return "~" + path[len(home):] if path.startswith(home) else path

    def fmt_dirs(dirs_list: list) -> str:
        joined = ", ".join(collapse(d) for d in dirs_list)
        return joined[:39] + "…" if len(joined) > 40 else joined

    def fmt_time(ts: str) -> str:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%Y-%m-%d %H:%M")

    sorted_all = sorted(all_ws, key=lambda w: w["last_used_at"], reverse=True)
    typer.echo(f"{'NAME':<20}{'STATUS':<10}{'DIRS':<42}LAST USED")
    typer.echo("-" * 85)
    for w in sorted_all:
        typer.echo(
            f"{w['name']:<20}{w['status']:<10}{fmt_dirs(w['dirs']):<42}{fmt_time(w['last_used_at'])}"
        )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
.venv/bin/pytest tests/test_cli.py -v
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add claudespaces/cli.py tests/test_cli.py
git commit -m "feat: replace implicit entry point with explicit new/start commands"
```

---

### Task 4: Delete `sessions.py` and `test_sessions.py`, update CLAUDE.md

**Files:**

- Delete: `claudespaces/sessions.py`
- Delete: `tests/test_sessions.py`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Delete the old files**

```bash
git rm claudespaces/sessions.py tests/test_sessions.py
```

- [ ] **Step 2: Update CLAUDE.md**

In `CLAUDE.md`, find the architecture section and update the module description. Replace:

```
- **`sessions.py`** — JSON state CRUD at `~/.claudespaces/sessions.json`; `STATE_FILE` is a module-level constant that tests monkeypatch
```

With:

```
- **`workspaces.py`** — JSON state CRUD at `~/.claudespaces/workspaces.json`; `STATE_FILE` is a module-level constant that tests monkeypatch; migrates automatically from `sessions.json` on first load
```

Also update the key design decisions section — replace the "Session lifecycle" paragraph with:

```
**Workspace lifecycle:** `status` is set to `"running"` before `attach_container` and back to `"stopped"` in a `try/finally` — this survives Python exceptions and `KeyboardInterrupt`. Auto-heal on startup detects containers that are no longer running (reboot, crash) and marks their workspaces stopped. Multiple workspaces for the same dir-set are valid. Names are unique across all workspaces.
```

And update the Testing note to reference `workspaces`:

```
**Testing:** All Docker calls are mocked — no daemon required. Workspace tests monkeypatch `STATE_FILE` to `tmp_path`. CLI tests patch at the `claudespaces.cli.*` module boundary (e.g. `claudespaces.cli.docker`, `claudespaces.cli.workspaces`).
```

- [ ] **Step 3: Run full test suite**

```bash
.venv/bin/pytest -v
```

Expected: all tests PASS, no references to `sessions` remain in test output.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "chore: remove sessions module, update docs for workspace rename"
```

---

### Task 5: Final verification

- [ ] **Step 1: Run the full test suite one last time**

```bash
.venv/bin/pytest -v
```

Expected: all tests PASS.

- [ ] **Step 2: Confirm no lingering session references**

```bash
grep -r "sessions" claudespaces/ tests/ --include="*.py"
```

Expected: no output (zero matches).

- [ ] **Step 3: Smoke test (requires Docker)**

```bash
claudespaces new --named test-ws .
claudespaces list
claudespaces start test-ws
# (detach with Ctrl-D or exit)
claudespaces start test-ws   # should print: Workspace 'test-ws' is already running.
claudespaces stop test-ws
claudespaces remove test-ws
claudespaces list            # should print: No workspaces found.
```
