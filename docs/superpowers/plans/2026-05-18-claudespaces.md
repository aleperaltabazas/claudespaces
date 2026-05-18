# claudespaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Python CLI tool that launches persistent Docker containers running interactive Claude Code sessions, with full session lifecycle management.

**Architecture:** Five focused modules (`config`, `sessions`, `image`, `container`, `cli`) with `cli.py` as the integration layer. All external I/O (Docker, filesystem, questionary) is isolated in leaf modules so tests can mock at the module boundary. TDD throughout — tests first, then minimal implementation.

**Tech Stack:** Python 3.11+, Typer, Docker SDK (`docker`), questionary, PyYAML, pytest, pytest-mock

---

## File Map

| File | Purpose |
|------|---------|
| `pyproject.toml` | Package definition, dependencies, entry point |
| `claudespaces/__init__.py` | Empty package marker |
| `claudespaces/config.py` | Load `claudespaces.yml`; raise on conflicting keys |
| `claudespaces/sessions.py` | JSON state CRUD at `~/.claudespaces/sessions.json` |
| `claudespaces/image.py` | Resolve/build Docker image with claude pre-installed |
| `claudespaces/container.py` | Docker SDK operations: create/attach/stop/remove |
| `claudespaces/cli.py` | Typer app: main flow, list, stop, remove commands |
| `tests/test_config.py` | Unit tests for config.py |
| `tests/test_sessions.py` | Unit tests for sessions.py |
| `tests/test_image.py` | Unit tests for image.py |
| `tests/test_container.py` | Unit tests for container.py |
| `tests/test_cli.py` | Integration tests via CliRunner |

---

## Task 1: Project Scaffold

**Files:**
- Create: `pyproject.toml`
- Create: `claudespaces/__init__.py`
- Create: `tests/__init__.py`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p claudespaces tests
```

- [ ] **Step 2: Write `pyproject.toml`**

```toml
[build-system]
requires = ["setuptools"]
build-backend = "setuptools.backends.legacy:build"

[project]
name = "claudespaces"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "typer>=0.12",
    "questionary>=2.0",
    "docker>=7.0",
    "pyyaml>=6.0",
]

[project.optional-dependencies]
dev = ["pytest>=8.0", "pytest-mock>=3.0"]

[project.scripts]
claudespaces = "claudespaces.cli:app"
```

- [ ] **Step 3: Create package and test markers**

Create `claudespaces/__init__.py` — empty file.

Create `tests/__init__.py` — empty file.

- [ ] **Step 4: Install in editable mode**

```bash
pip install -e ".[dev]"
```

Expected: installs successfully, `claudespaces` command available.

- [ ] **Step 5: Commit**

```bash
git add pyproject.toml claudespaces/__init__.py tests/__init__.py
git commit -m "feat: add project scaffold"
```

---

## Task 2: `config.py`

**Files:**
- Create: `tests/test_config.py`
- Create: `claudespaces/config.py`

- [ ] **Step 1: Write failing tests**

`tests/test_config.py`:

```python
import pytest
from pathlib import Path
from claudespaces.config import load_config


def test_returns_empty_dict_when_no_config(tmp_path):
    assert load_config(str(tmp_path)) == {}


def test_parses_image_key(tmp_path):
    (tmp_path / "claudespaces.yml").write_text("image: ubuntu:24.04\n")
    assert load_config(str(tmp_path))["image"] == "ubuntu:24.04"


def test_parses_dockerfile_key(tmp_path):
    (tmp_path / "claudespaces.yml").write_text("dockerfile: ./Dockerfile\n")
    assert load_config(str(tmp_path))["dockerfile"] == "./Dockerfile"


def test_raises_on_both_image_and_dockerfile(tmp_path):
    (tmp_path / "claudespaces.yml").write_text("image: foo\ndockerfile: ./Dockerfile\n")
    with pytest.raises(ValueError, match="mutually exclusive"):
        load_config(str(tmp_path))


def test_parses_directories(tmp_path):
    (tmp_path / "claudespaces.yml").write_text("directories:\n  - ~/proj1\n  - ~/proj2\n")
    assert load_config(str(tmp_path))["directories"] == ["~/proj1", "~/proj2"]


def test_empty_yaml_returns_empty_dict(tmp_path):
    (tmp_path / "claudespaces.yml").write_text("")
    assert load_config(str(tmp_path)) == {}
```

- [ ] **Step 2: Run to verify they fail**

```bash
pytest tests/test_config.py -v
```

Expected: `ImportError` — `claudespaces.config` does not exist yet.

- [ ] **Step 3: Write implementation**

`claudespaces/config.py`:

```python
from pathlib import Path
import yaml


def load_config(cwd: str = ".") -> dict:
    path = Path(cwd) / "claudespaces.yml"
    if not path.exists():
        return {}
    with open(path) as f:
        config = yaml.safe_load(f) or {}
    if "image" in config and "dockerfile" in config:
        raise ValueError("claudespaces.yml: 'image' and 'dockerfile' are mutually exclusive")
    return config
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest tests/test_config.py -v
```

Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add claudespaces/config.py tests/test_config.py
git commit -m "feat: add config.py with claudespaces.yml loader"
```

---

## Task 3: `sessions.py`

**Files:**
- Create: `tests/test_sessions.py`
- Create: `claudespaces/sessions.py`

- [ ] **Step 1: Write failing tests**

`tests/test_sessions.py`:

```python
import pytest
from claudespaces import sessions


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    monkeypatch.setattr(sessions, "STATE_FILE", tmp_path / "sessions.json")


def _s(**kwargs):
    base = {
        "id": "abc12345",
        "name": "bold-space",
        "dirs": ["/home/user/proj1"],
        "container_id": "container123",
        "image": "claudespaces-base:ubuntu-24.04",
        "created_at": "2026-05-18T10:00:00Z",
        "last_used_at": "2026-05-18T12:00:00Z",
        "status": "stopped",
    }
    return {**base, **kwargs}


def test_save_and_read_back():
    sessions.save_session(_s())
    result = sessions.all_sessions()
    assert len(result) == 1
    assert result[0]["id"] == "abc12345"


def test_get_sessions_for_dirs_matches_exact_sorted():
    sessions.save_session(_s(id="aaa", dirs=["/a", "/b"]))
    sessions.save_session(_s(id="bbb", dirs=["/a"]))
    result = sessions.get_sessions_for_dirs(["/b", "/a"])
    assert len(result) == 1
    assert result[0]["id"] == "aaa"


def test_get_sessions_for_dirs_no_match():
    sessions.save_session(_s(id="aaa", dirs=["/a"]))
    assert sessions.get_sessions_for_dirs(["/b"]) == []


def test_get_session_by_id_found():
    sessions.save_session(_s(id="abc12345"))
    result = sessions.get_session_by_id("abc12345")
    assert result is not None
    assert result["id"] == "abc12345"


def test_get_session_by_id_not_found():
    assert sessions.get_session_by_id("nope") is None


def test_update_session_changes_fields():
    sessions.save_session(_s(id="abc12345", status="running"))
    sessions.update_session("abc12345", status="stopped")
    assert sessions.get_session_by_id("abc12345")["status"] == "stopped"


def test_update_session_leaves_other_fields_intact():
    sessions.save_session(_s(id="abc12345", name="bold-space", status="running"))
    sessions.update_session("abc12345", status="stopped")
    assert sessions.get_session_by_id("abc12345")["name"] == "bold-space"


def test_remove_session_removes_correct_record():
    sessions.save_session(_s(id="aaa"))
    sessions.save_session(_s(id="bbb"))
    sessions.remove_session("aaa")
    remaining = sessions.all_sessions()
    assert len(remaining) == 1
    assert remaining[0]["id"] == "bbb"


def test_all_sessions_returns_all():
    sessions.save_session(_s(id="aaa"))
    sessions.save_session(_s(id="bbb"))
    assert len(sessions.all_sessions()) == 2


def test_heal_marks_stale_running_as_stopped():
    sessions.save_session(_s(id="aaa", status="running", container_id="c1"))
    sessions.heal_running_sessions(set())
    assert sessions.get_session_by_id("aaa")["status"] == "stopped"


def test_heal_leaves_actually_running_unchanged():
    sessions.save_session(_s(id="aaa", status="running", container_id="c1"))
    sessions.heal_running_sessions({"c1"})
    assert sessions.get_session_by_id("aaa")["status"] == "running"


def test_heal_leaves_stopped_sessions_unchanged():
    sessions.save_session(_s(id="aaa", status="stopped", container_id="c1"))
    sessions.heal_running_sessions(set())
    assert sessions.get_session_by_id("aaa")["status"] == "stopped"


def test_heal_only_changes_stale_not_all():
    sessions.save_session(_s(id="aaa", status="running", container_id="c1"))
    sessions.save_session(_s(id="bbb", status="running", container_id="c2"))
    sessions.heal_running_sessions({"c2"})
    assert sessions.get_session_by_id("aaa")["status"] == "stopped"
    assert sessions.get_session_by_id("bbb")["status"] == "running"


def test_generate_name_format():
    name = sessions.generate_name(set())
    parts = name.split("-")
    assert len(parts) == 2
    assert parts[0] in sessions.ADJECTIVES
    assert parts[1] in sessions.NOUNS


def test_generate_name_avoids_collisions():
    all_names = {
        f"{adj}-{noun}"
        for adj in sessions.ADJECTIVES
        for noun in sessions.NOUNS
        if not (adj == sessions.ADJECTIVES[0] and noun == sessions.NOUNS[0])
    }
    name = sessions.generate_name(all_names)
    assert name not in all_names
    assert name == f"{sessions.ADJECTIVES[0]}-{sessions.NOUNS[0]}"
```

- [ ] **Step 2: Run to verify they fail**

```bash
pytest tests/test_sessions.py -v
```

Expected: `ImportError` — `claudespaces.sessions` does not exist yet.

- [ ] **Step 3: Write implementation**

`claudespaces/sessions.py`:

```python
import json
import random
from pathlib import Path

STATE_FILE = Path.home() / ".claudespaces" / "sessions.json"

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
    "star", "stone", "storm",
]


def _load() -> list[dict]:
    if not STATE_FILE.exists():
        return []
    with open(STATE_FILE) as f:
        return json.load(f)


def _save(session_list: list[dict]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(session_list, f, indent=2)


def all_sessions() -> list[dict]:
    return _load()


def get_sessions_for_dirs(dirs: list[str]) -> list[dict]:
    key = sorted(dirs)
    return [s for s in _load() if s["dirs"] == key]


def get_session_by_id(session_id: str) -> dict | None:
    for s in _load():
        if s["id"] == session_id:
            return s
    return None


def save_session(session: dict) -> None:
    data = _load()
    data.append(session)
    _save(data)


def update_session(session_id: str, **fields) -> None:
    data = _load()
    for s in data:
        if s["id"] == session_id:
            s.update(fields)
    _save(data)


def remove_session(session_id: str) -> None:
    _save([s for s in _load() if s["id"] != session_id])


def heal_running_sessions(running_container_ids: set[str]) -> None:
    data = _load()
    changed = False
    for s in data:
        if s["status"] == "running" and s["container_id"] not in running_container_ids:
            s["status"] = "stopped"
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
pytest tests/test_sessions.py -v
```

Expected: all 15 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add claudespaces/sessions.py tests/test_sessions.py
git commit -m "feat: add sessions.py with JSON state CRUD"
```

---

## Task 4: `image.py`

**Files:**
- Create: `tests/test_image.py`
- Create: `claudespaces/image.py`

- [ ] **Step 1: Write failing tests**

`tests/test_image.py`:

```python
import pytest
from unittest.mock import MagicMock, call
import docker
from claudespaces.image import resolve_image


@pytest.fixture
def client():
    c = MagicMock()
    c.images.build.return_value = (MagicMock(), [])
    return c


def test_default_returns_ubuntu_tag(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image(None, None, client)
    assert result == "claudespaces-base:ubuntu-24.04"


def test_named_image_derives_tag(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image("myrepo/img:tag", None, client)
    assert result == "claudespaces-base:myrepo-img-tag"


def test_named_image_colon_slash_replaced(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image("registry.io/org/image:v1.2", None, client)
    assert result == "claudespaces-base:registry.io-org-image-v1.2"


def test_missing_dockerfile_raises_file_not_found(client, tmp_path):
    with pytest.raises(FileNotFoundError):
        resolve_image(None, str(tmp_path / "Dockerfile"), client)


def test_cache_hit_skips_build(client):
    client.images.get.return_value = MagicMock()  # image exists
    result = resolve_image(None, None, client)
    assert result == "claudespaces-base:ubuntu-24.04"
    client.images.build.assert_not_called()


def test_cache_miss_triggers_build(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, None, client)
    client.images.build.assert_called_once()
    kwargs = client.images.build.call_args.kwargs
    assert kwargs["tag"] == "claudespaces-base:ubuntu-24.04"


def test_dockerfile_triggers_two_builds(client, tmp_path):
    dockerfile = tmp_path / "Dockerfile"
    dockerfile.write_text("FROM ubuntu:24.04\n")
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, str(dockerfile), client)
    assert client.images.build.call_count == 2
```

- [ ] **Step 2: Run to verify they fail**

```bash
pytest tests/test_image.py -v
```

Expected: `ImportError` — `claudespaces.image` does not exist yet.

- [ ] **Step 3: Write implementation**

`claudespaces/image.py`:

```python
import hashlib
import os
import re
import tempfile

import docker


def resolve_image(image: str | None, dockerfile: str | None, docker_client) -> str:
    if dockerfile is not None:
        if not os.path.exists(dockerfile):
            raise FileNotFoundError(f"Dockerfile not found: {dockerfile}")
        abs_path = os.path.abspath(dockerfile)
        path_slug = hashlib.md5(abs_path.encode()).hexdigest()[:12]
        base_tag = f"claudespaces-custom:{path_slug}"
        docker_client.images.build(
            path=os.path.dirname(abs_path),
            dockerfile=os.path.basename(abs_path),
            tag=base_tag,
        )
    elif image is not None:
        base_tag = image
    else:
        base_tag = "ubuntu:24.04"

    intermediate_tag = "claudespaces-base:" + re.sub(r"[:/]", "-", base_tag)

    try:
        docker_client.images.get(intermediate_tag)
        return intermediate_tag
    except docker.errors.ImageNotFound:
        pass

    dockerfile_content = (
        f"FROM {base_tag}\n"
        "RUN apt-get update && apt-get install -y curl && \\\n"
        "    curl -fsSL https://claude.ai/install.sh | sh\n"
    )
    with tempfile.TemporaryDirectory() as tmpdir:
        with open(os.path.join(tmpdir, "Dockerfile"), "w") as f:
            f.write(dockerfile_content)
        docker_client.images.build(path=tmpdir, tag=intermediate_tag)

    return intermediate_tag
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest tests/test_image.py -v
```

Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add claudespaces/image.py tests/test_image.py
git commit -m "feat: add image.py with claude install layer resolution"
```

---

## Task 5: `container.py`

**Files:**
- Create: `tests/test_container.py`
- Create: `claudespaces/container.py`

- [ ] **Step 1: Write failing tests**

`tests/test_container.py`:

```python
import pytest
from unittest.mock import MagicMock, patch
import docker
from docker.types import Mount
from claudespaces.container import (
    create_container,
    get_running_container_ids,
    stop_container,
    remove_container,
)


@pytest.fixture
def client():
    c = MagicMock()
    c.containers.create.return_value = MagicMock(id="container123")
    return c


def test_create_raises_on_basename_collision(client, tmp_path):
    dir_a = tmp_path / "group1" / "myapp"
    dir_b = tmp_path / "group2" / "myapp"
    dir_a.mkdir(parents=True)
    dir_b.mkdir(parents=True)
    with pytest.raises(ValueError, match="basename"):
        create_container(client, "image", [str(dir_a), str(dir_b)], "/fake/.claude")


def test_create_skips_missing_claude_paths(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()

    create_container(client, "image", [str(proj)], str(claude_dir))

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert targets == ["/workspace/proj"]


def test_create_includes_existing_claude_credentials(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()
    (claude_dir / ".credentials.json").write_text("{}")

    create_container(client, "image", [str(proj)], str(claude_dir))

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/root/.claude/.credentials.json" in targets


def test_create_includes_all_existing_claude_paths(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()
    (claude_dir / ".credentials.json").write_text("{}")
    (claude_dir / "settings.json").write_text("{}")
    (claude_dir / "CLAUDE.md").write_text("")
    (claude_dir / "plugins").mkdir()
    (claude_dir / "skills").mkdir()

    create_container(client, "image", [str(proj)], str(claude_dir))

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/root/.claude/.credentials.json" in targets
    assert "/root/.claude/settings.json" in targets
    assert "/root/.claude/CLAUDE.md" in targets
    assert "/root/.claude/plugins" in targets
    assert "/root/.claude/skills" in targets


def test_create_mounts_user_dir_at_workspace_basename(client, tmp_path):
    proj = tmp_path / "myproject"
    proj.mkdir()
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()

    create_container(client, "image", [str(proj)], str(claude_dir))

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/workspace/myproject" in targets


def test_create_user_dir_mount_is_readwrite(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()

    create_container(client, "image", [str(proj)], str(claude_dir))

    kwargs = client.containers.create.call_args.kwargs
    user_mount = next(m for m in kwargs["mounts"] if m["Target"] == "/workspace/proj")
    assert user_mount["ReadOnly"] is False


def test_create_claude_mount_is_readonly(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()
    (claude_dir / "settings.json").write_text("{}")

    create_container(client, "image", [str(proj)], str(claude_dir))

    kwargs = client.containers.create.call_args.kwargs
    settings_mount = next(m for m in kwargs["mounts"] if m["Target"] == "/root/.claude/settings.json")
    assert settings_mount["ReadOnly"] is True


def test_create_sets_container_options(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()

    create_container(client, "claudespaces-base:ubuntu-24.04", [str(proj)], str(claude_dir))

    kwargs = client.containers.create.call_args.kwargs
    assert kwargs["tty"] is True
    assert kwargs["stdin_open"] is True
    assert kwargs["working_dir"] == "/workspace"
    assert kwargs["command"] == ["claude"]


def test_create_returns_container_id(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    claude_dir = tmp_path / ".claude"
    claude_dir.mkdir()

    result = create_container(client, "image", [str(proj)], str(claude_dir))

    assert result == "container123"


def test_get_running_container_ids(client):
    c1, c2 = MagicMock(id="abc"), MagicMock(id="def")
    client.containers.list.return_value = [c1, c2]
    result = get_running_container_ids(client)
    assert result == {"abc", "def"}
    client.containers.list.assert_called_once_with(filters={"status": "running"})


def test_remove_container_ignores_not_found(client):
    client.containers.get.return_value.remove.side_effect = docker.errors.NotFound("gone")
    remove_container(client, "c1")  # should not raise


def test_stop_container_calls_stop(client):
    stop_container(client, "c1")
    client.containers.get.assert_called_once_with("c1")
    client.containers.get.return_value.stop.assert_called_once()
```

- [ ] **Step 2: Run to verify they fail**

```bash
pytest tests/test_container.py -v
```

Expected: `ImportError` — `claudespaces.container` does not exist yet.

- [ ] **Step 3: Write implementation**

`claudespaces/container.py`:

```python
import os
import subprocess

import docker
from docker.types import Mount

CLAUDE_CONFIG_PATHS = [
    (".credentials.json", "/root/.claude/.credentials.json"),
    ("settings.json", "/root/.claude/settings.json"),
    ("CLAUDE.md", "/root/.claude/CLAUDE.md"),
    ("plugins", "/root/.claude/plugins"),
    ("skills", "/root/.claude/skills"),
]


def get_running_container_ids(docker_client) -> set[str]:
    containers = docker_client.containers.list(filters={"status": "running"})
    return {c.id for c in containers}


def create_container(docker_client, image: str, dirs: list[str], claude_dir: str) -> str:
    basenames = [os.path.basename(d) for d in dirs]
    if len(basenames) != len(set(basenames)):
        dup = next(b for b in basenames if basenames.count(b) > 1)
        raise ValueError(f"Directories share the same basename: {dup!r}")

    mounts = []

    for d in dirs:
        mounts.append(Mount(
            target=f"/workspace/{os.path.basename(d)}",
            source=d,
            type="bind",
            read_only=False,
        ))

    for rel_path, container_path in CLAUDE_CONFIG_PATHS:
        host_path = os.path.join(claude_dir, rel_path)
        if os.path.exists(host_path):
            mounts.append(Mount(
                target=container_path,
                source=host_path,
                type="bind",
                read_only=True,
            ))

    container = docker_client.containers.create(
        image=image,
        command=["claude"],
        tty=True,
        stdin_open=True,
        working_dir="/workspace",
        mounts=mounts,
    )
    return container.id


def attach_container(container_id: str) -> int:
    result = subprocess.run(["docker", "start", "-ai", container_id])
    return result.returncode


def stop_container(docker_client, container_id: str) -> None:
    docker_client.containers.get(container_id).stop()


def remove_container(docker_client, container_id: str) -> None:
    try:
        docker_client.containers.get(container_id).remove(force=True)
    except docker.errors.NotFound:
        pass
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest tests/test_container.py -v
```

Expected: all 12 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add claudespaces/container.py tests/test_container.py
git commit -m "feat: add container.py with Docker SDK operations"
```

---

## Task 6: `cli.py`

**Files:**
- Create: `tests/test_cli.py`
- Create: `claudespaces/cli.py`

- [ ] **Step 1: Write failing tests**

`tests/test_cli.py`:

```python
import pytest
from unittest.mock import MagicMock, patch
from typer.testing import CliRunner
from claudespaces.cli import app

runner = CliRunner(mix_stderr=False)


@pytest.fixture
def mock_docker(mocker):
    client = MagicMock()
    mocker.patch("claudespaces.cli.docker.from_env", return_value=client)
    return client


@pytest.fixture
def mock_sessions(mocker):
    m = mocker.patch("claudespaces.cli.sessions")
    m.get_sessions_for_dirs.return_value = []
    m.all_sessions.return_value = []
    m.heal_running_sessions.return_value = None
    m.generate_name.return_value = "bold-space"
    return m


@pytest.fixture
def mock_container(mocker):
    m = mocker.patch("claudespaces.cli.container")
    m.get_running_container_ids.return_value = set()
    m.create_container.return_value = "container123"
    m.attach_container.return_value = 0
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


@pytest.fixture
def mock_questionary(mocker):
    return mocker.patch("claudespaces.cli.questionary")


def test_exits_1_when_docker_unreachable(mocker, tmp_path, mock_config):
    mocker.patch("claudespaces.cli.docker.from_env", side_effect=Exception("no docker"))
    proj = tmp_path / "proj"
    proj.mkdir()
    result = runner.invoke(app, [str(proj)])
    assert result.exit_code == 1
    assert "Docker is not running" in result.output


def test_exits_1_when_directory_not_found(mock_docker, mock_config):
    result = runner.invoke(app, ["/nonexistent/path/xyz"])
    assert result.exit_code == 1
    assert "Directory not found" in result.output


def test_exits_1_when_path_is_not_a_directory(mock_docker, mock_config, tmp_path):
    f = tmp_path / "file.txt"
    f.write_text("hello")
    result = runner.invoke(app, [str(f)])
    assert result.exit_code == 1
    assert "Not a directory" in result.output


def test_first_run_no_sessions_creates_container(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    mock_sessions.get_sessions_for_dirs.return_value = []

    result = runner.invoke(app, [str(proj)])

    mock_container.create_container.assert_called_once()
    mock_container.attach_container.assert_called_once_with("container123")
    assert result.exit_code == 0


def test_first_run_saves_session(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    mock_sessions.get_sessions_for_dirs.return_value = []

    runner.invoke(app, [str(proj)])

    mock_sessions.save_session.assert_called_once()
    saved = mock_sessions.save_session.call_args.args[0]
    assert saved["status"] == "running"
    assert saved["name"] == "bold-space"


def test_session_marked_stopped_after_attach(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    mock_sessions.get_sessions_for_dirs.return_value = []

    runner.invoke(app, [str(proj)])

    mock_sessions.update_session.assert_called()
    update_kwargs = mock_sessions.update_session.call_args.kwargs
    assert update_kwargs["status"] == "stopped"


def test_existing_sessions_shows_selector(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config, mock_questionary
):
    proj = tmp_path / "proj"
    proj.mkdir()
    existing = [{
        "id": "abc12345", "name": "bold-space", "dirs": [str(proj)],
        "container_id": "c1", "status": "stopped",
        "last_used_at": "2026-05-17T14:32:00Z",
    }]
    mock_sessions.get_sessions_for_dirs.return_value = existing
    mock_questionary.select.return_value.ask.return_value = "__new__"
    mock_questionary.Choice = MagicMock(side_effect=lambda *a, **kw: {"title": a[0], **kw})

    runner.invoke(app, [str(proj)])

    mock_questionary.select.assert_called_once()


def test_running_sessions_are_disabled_in_selector(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config, mock_questionary
):
    proj = tmp_path / "proj"
    proj.mkdir()
    existing = [{
        "id": "abc12345", "name": "bold-space", "dirs": [str(proj)],
        "container_id": "c1", "status": "running",
        "last_used_at": "2026-05-17T14:32:00Z",
    }]
    mock_sessions.get_sessions_for_dirs.return_value = existing

    choices_captured = []
    def capture_select(prompt, choices):
        choices_captured.extend(choices)
        return MagicMock(ask=MagicMock(return_value=None))

    mock_questionary.select.side_effect = capture_select
    mock_questionary.Choice.side_effect = lambda title, value=None, disabled=None: {
        "title": title, "value": value, "disabled": disabled
    }

    runner.invoke(app, [str(proj)])

    running_choice = next(c for c in choices_captured if c.get("value") == "abc12345")
    assert running_choice["disabled"]


def test_selecting_new_session_creates_container(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config, mock_questionary
):
    proj = tmp_path / "proj"
    proj.mkdir()
    existing = [{
        "id": "abc12345", "name": "bold-space", "dirs": [str(proj)],
        "container_id": "c1", "status": "stopped",
        "last_used_at": "2026-05-17T14:32:00Z",
    }]
    mock_sessions.get_sessions_for_dirs.return_value = existing
    mock_questionary.Choice = MagicMock(side_effect=lambda *a, **kw: {"value": kw.get("value", a[0] if a else None)})
    mock_questionary.select.return_value.ask.return_value = "__new__"

    runner.invoke(app, [str(proj)])

    mock_container.create_container.assert_called_once()


def test_selecting_existing_session_resumes_it(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config, mock_questionary
):
    proj = tmp_path / "proj"
    proj.mkdir()
    existing = [{
        "id": "abc12345", "name": "bold-space", "dirs": [str(proj)],
        "container_id": "c1", "status": "stopped",
        "last_used_at": "2026-05-17T14:32:00Z",
    }]
    mock_sessions.get_sessions_for_dirs.return_value = existing
    mock_sessions.get_session_by_id.return_value = existing[0]
    mock_questionary.Choice = MagicMock(side_effect=lambda *a, **kw: {"value": kw.get("value", a[0] if a else None)})
    mock_questionary.select.return_value.ask.return_value = "abc12345"

    runner.invoke(app, [str(proj)])

    mock_container.create_container.assert_not_called()
    mock_container.attach_container.assert_called_once_with("c1")


def test_selector_cancel_exits_cleanly(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config, mock_questionary
):
    proj = tmp_path / "proj"
    proj.mkdir()
    existing = [{
        "id": "abc12345", "name": "bold-space", "dirs": [str(proj)],
        "container_id": "c1", "status": "stopped",
        "last_used_at": "2026-05-17T14:32:00Z",
    }]
    mock_sessions.get_sessions_for_dirs.return_value = existing
    mock_questionary.Choice = MagicMock(side_effect=lambda *a, **kw: kw)
    mock_questionary.select.return_value.ask.return_value = None

    result = runner.invoke(app, [str(proj)])

    assert result.exit_code == 0
    mock_container.create_container.assert_not_called()


def test_list_no_sessions(mock_sessions):
    mock_sessions.all_sessions.return_value = []
    result = runner.invoke(app, ["list"])
    assert result.exit_code == 0
    assert "No sessions found." in result.output


def test_list_with_sessions(mock_sessions):
    mock_sessions.all_sessions.return_value = [{
        "id": "abc12345",
        "name": "bold-space",
        "dirs": ["/home/user/proj1"],
        "container_id": "c1",
        "status": "stopped",
        "last_used_at": "2026-05-17T14:32:00Z",
        "created_at": "2026-05-17T10:00:00Z",
        "image": "claudespaces-base:ubuntu-24.04",
    }]
    result = runner.invoke(app, ["list"])
    assert result.exit_code == 0
    assert "abc12345" in result.output
    assert "bold-space" in result.output
    assert "stopped" in result.output


def test_stop_unknown_session_exits_1(mock_sessions):
    mock_sessions.get_session_by_id.return_value = None
    result = runner.invoke(app, ["stop", "badid"])
    assert result.exit_code == 1
    assert "Session not found: badid" in result.output


def test_stop_already_stopped_session(mock_docker, mock_sessions):
    mock_sessions.get_session_by_id.return_value = {
        "id": "abc12345", "name": "bold-space", "container_id": "c1", "status": "stopped"
    }
    result = runner.invoke(app, ["stop", "abc12345"])
    assert result.exit_code == 0
    assert "already stopped" in result.output


def test_stop_running_session(mock_docker, mock_sessions, mock_container):
    mock_sessions.get_session_by_id.return_value = {
        "id": "abc12345", "name": "bold-space", "container_id": "c1", "status": "running"
    }
    result = runner.invoke(app, ["stop", "abc12345"])
    assert result.exit_code == 0
    mock_container.stop_container.assert_called_once()
    mock_sessions.update_session.assert_called_once_with("abc12345", status="stopped")
    assert "Stopped session bold-space" in result.output


def test_remove_unknown_session_exits_1(mock_sessions):
    mock_sessions.get_session_by_id.return_value = None
    result = runner.invoke(app, ["remove", "badid"])
    assert result.exit_code == 1
    assert "Session not found: badid" in result.output


def test_remove_session(mock_docker, mock_sessions, mock_container):
    mock_sessions.get_session_by_id.return_value = {
        "id": "abc12345", "name": "bold-space", "container_id": "c1", "status": "stopped"
    }
    result = runner.invoke(app, ["remove", "abc12345"])
    assert result.exit_code == 0
    mock_container.remove_container.assert_called_once()
    mock_sessions.remove_session.assert_called_once_with("abc12345")
    assert "Removed session bold-space" in result.output


def test_remove_when_container_already_gone(mock_docker, mock_sessions, mock_container):
    mock_sessions.get_session_by_id.return_value = {
        "id": "abc12345", "name": "bold-space", "container_id": "c1", "status": "stopped"
    }
    mock_container.remove_container.return_value = None  # NotFound already swallowed in container.py
    result = runner.invoke(app, ["remove", "abc12345"])
    assert result.exit_code == 0
    mock_sessions.remove_session.assert_called_once_with("abc12345")


def test_no_dirs_no_config_exits_1(mock_config):
    # CLI exits before Docker check; CWD has no claudespaces.yml so Path check is False naturally
    mock_config.load_config.return_value = {}
    result = runner.invoke(app, [])
    assert result.exit_code == 1
    assert "No directories specified" in result.output
```

- [ ] **Step 2: Run to verify they fail**

```bash
pytest tests/test_cli.py -v
```

Expected: `ImportError` — `claudespaces.cli` does not exist yet.

- [ ] **Step 3: Write implementation**

`claudespaces/cli.py`:

```python
import os
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import docker
import questionary
import typer

from claudespaces import config, container, image, sessions

app = typer.Typer()


def _now_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@app.callback(invoke_without_command=True)
def main(
    ctx: typer.Context,
    dirs: Optional[list[str]] = typer.Argument(default=None),
    image_name: Optional[str] = typer.Option(None, "--image"),
    dockerfile: Optional[str] = typer.Option(None, "--dockerfile"),
) -> None:
    if ctx.invoked_subcommand is not None:
        return

    try:
        cfg = config.load_config()
    except ValueError as e:
        typer.echo(str(e))
        raise typer.Exit(1)

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
            typer.echo("No directories specified. Usage: claudespaces DIR [DIR...]")
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

    credentials_path = Path.home() / ".claude" / ".credentials.json"
    if not credentials_path.exists():
        typer.echo(
            "Warning: ~/.claude/.credentials.json not found. "
            "Claude will prompt you to log in inside the container."
        )

    if dockerfile:
        dockerfile = os.path.abspath(os.path.expanduser(dockerfile))

    try:
        resolved_image = image.resolve_image(image_name, dockerfile, docker_client)
    except FileNotFoundError as e:
        typer.echo(str(e))
        raise typer.Exit(1)
    except docker.errors.BuildError as e:
        typer.echo(f"Docker build failed: {e}")
        raise typer.Exit(1)

    running_ids = container.get_running_container_ids(docker_client)
    sessions.heal_running_sessions(running_ids)

    existing = sessions.get_sessions_for_dirs(resolved_dirs)

    if not existing:
        action = "new"
        selected = None
    else:
        choices = [questionary.Choice("[ New session ]", value="__new__")]
        for s in existing:
            dt = datetime.fromisoformat(s["last_used_at"].replace("Z", "+00:00"))
            local_time = dt.astimezone().strftime("%Y-%m-%d %H:%M")
            label = f"{s['name']}   {s['status']}   {local_time}"
            is_running = s["status"] == "running"
            choices.append(questionary.Choice(
                label,
                value=s["id"],
                disabled="running" if is_running else False,
            ))

        try:
            selected_id = questionary.select("Select a session:", choices=choices).ask()
        except KeyboardInterrupt:
            raise typer.Exit(0)

        if selected_id is None:
            raise typer.Exit(0)

        if selected_id == "__new__":
            action = "new"
            selected = None
        else:
            action = "resume"
            selected = sessions.get_session_by_id(selected_id)

    claude_dir = str(Path.home() / ".claude")

    if action == "new":
        container_id = container.create_container(
            docker_client, resolved_image, resolved_dirs, claude_dir
        )
        existing_names = {s["name"] for s in sessions.all_sessions()}
        session = {
            "id": secrets.token_hex(4),
            "name": sessions.generate_name(existing_names),
            "dirs": resolved_dirs,
            "container_id": container_id,
            "image": resolved_image,
            "created_at": _now_utc(),
            "last_used_at": _now_utc(),
            "status": "running",
        }
        sessions.save_session(session)
        session_id = session["id"]
        try:
            container.attach_container(container_id)
        finally:
            sessions.update_session(session_id, status="stopped", last_used_at=_now_utc())
    else:
        session_id = selected["id"]
        container_id = selected["container_id"]
        sessions.update_session(session_id, status="running")
        try:
            container.attach_container(container_id)
        finally:
            sessions.update_session(session_id, status="stopped", last_used_at=_now_utc())


@app.command()
def list() -> None:
    all = sessions.all_sessions()
    if not all:
        typer.echo("No sessions found.")
        raise typer.Exit(0)

    home = str(Path.home())

    def collapse(path: str) -> str:
        return "~" + path[len(home):] if path.startswith(home) else path

    def fmt_dirs(dirs: list[str]) -> str:
        joined = ", ".join(collapse(d) for d in dirs)
        return joined[:39] + "…" if len(joined) > 40 else joined

    def fmt_time(ts: str) -> str:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%Y-%m-%d %H:%M")

    sorted_all = sorted(all, key=lambda s: s["last_used_at"], reverse=True)
    typer.echo(f"{'ID':<10}{'NAME':<14}{'STATUS':<10}{'DIRS':<42}LAST USED")
    typer.echo("-" * 90)
    for s in sorted_all:
        typer.echo(
            f"{s['id']:<10}{s['name']:<14}{s['status']:<10}{fmt_dirs(s['dirs']):<42}{fmt_time(s['last_used_at'])}"
        )


@app.command()
def stop(session_id: str) -> None:
    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    session = sessions.get_session_by_id(session_id)
    if session is None:
        typer.echo(f"Session not found: {session_id}")
        raise typer.Exit(1)

    if session["status"] == "stopped":
        typer.echo(f"Session {session['name']} ({session_id}) is already stopped.")
        raise typer.Exit(0)

    container.stop_container(docker_client, session["container_id"])
    sessions.update_session(session_id, status="stopped")
    typer.echo(f"Stopped session {session['name']} ({session_id}).")


@app.command()
def remove(session_id: str) -> None:
    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    session = sessions.get_session_by_id(session_id)
    if session is None:
        typer.echo(f"Session not found: {session_id}")
        raise typer.Exit(1)

    container.remove_container(docker_client, session["container_id"])
    sessions.remove_session(session_id)
    typer.echo(f"Removed session {session['name']} ({session_id}).")
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest tests/test_cli.py -v
```

Expected: all tests PASS.

- [ ] **Step 5: Run the full test suite**

```bash
pytest -v
```

Expected: all tests across all test files PASS.

- [ ] **Step 6: Commit**

```bash
git add claudespaces/cli.py tests/test_cli.py
git commit -m "feat: add cli.py — complete claudespaces CLI"
```

---

## Final Verification

- [ ] **Run full test suite one last time**

```bash
pytest -v --tb=short
```

Expected: all tests PASS, 0 failures.

- [ ] **Smoke-test the entry point is wired**

```bash
claudespaces --help
```

Expected: Typer help output showing `[DIRS...]`, `--image`, `--dockerfile` options and `list`, `stop`, `remove` subcommands.
