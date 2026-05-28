# Host Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a host bridge that lets claudespaces containers invoke a configurable set of host-side operations (e.g. `notify-send`) via a lightweight HTTP server spawned alongside the container.

**Architecture:** A stdlib HTTP server listens on `localhost:7731` (configurable); `cli.py` starts it when the first workspace starts and kills it when the last one stops. A `claudespaces-host` script bind-mounted into every container POSTs requests to `host.docker.internal:<port>/run`. Operations with an `override` field get a shim script injected at container startup via `entrypoint.sh`.

**Tech Stack:** Python 3 (stdlib only: `http.server`, `subprocess`, `socket`, `urllib`), Bash (entrypoint shim injection), PyYAML (already a dependency), pytest + pytest-mock (already dev dependencies).

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `claudespaces/host_config.py` | Load `host_bridge` from global config, merge with built-in ops, produce shims manifest |
| Create | `claudespaces/host_server.py` | HTTP handler logic, server lifecycle helpers (`is_running`, `start_server`, `stop_server_if_last`) |
| Create | `claudespaces/support/bin/claudespaces-host` | Python script installed in container; sends requests to the bridge server |
| Modify | `claudespaces/Dockerfile.base` | Copy `claudespaces-host` into image; create `/claudespaces/bin/` |
| Modify | `claudespaces/container.py` | Mount `shims.json` and `claudespaces-host`; inject `CLAUDESPACES_HOST_PORT` env var |
| Modify | `claudespaces/support/bin/entrypoint.sh` | Add `/claudespaces/bin` to PATH; inject shims on startup |
| Modify | `claudespaces/cli.py` | Write shims manifest in `new`; start/stop bridge in `new --start` and `start`/`stop` |
| Create | `tests/test_host_config.py` | Unit tests for config loading and manifest generation |
| Create | `tests/test_host_server.py` | Unit tests for `handle_run` and server lifecycle helpers |
| Modify | `tests/test_cli.py` | Tests for bridge start/stop behaviour in `start` and `stop` commands |

---

## Task 1: `host_config.py` — config loading and shims manifest

**Files:**
- Create: `claudespaces/host_config.py`
- Create: `tests/test_host_config.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_host_config.py
import yaml
import pytest
from claudespaces.host_config import (
    load_host_bridge,
    overrides_manifest,
    DEFAULT_PORT,
    SHIMS_PATH,
)


def test_returns_default_port_when_no_config(tmp_path, monkeypatch):
    monkeypatch.setattr("claudespaces.host_config.GLOBAL_CONFIG_PATH", tmp_path / "nope.yaml")
    result = load_host_bridge()
    assert result["port"] == DEFAULT_PORT


def test_builtin_notify_always_present(tmp_path, monkeypatch):
    cfg = tmp_path / "claudespaces.yaml"
    cfg.write_text("host_bridge:\n  operations: {}\n")
    monkeypatch.setattr("claudespaces.host_config.GLOBAL_CONFIG_PATH", cfg)
    result = load_host_bridge()
    assert "notify" in result["operations"]


def test_user_config_wins_on_conflict(tmp_path, monkeypatch):
    cfg = tmp_path / "claudespaces.yaml"
    cfg.write_text(yaml.dump({
        "host_bridge": {
            "operations": {
                "notify": {
                    "command": "custom-notify {msg}",
                    "args": ["msg"],
                    "async": True,
                }
            }
        }
    }))
    monkeypatch.setattr("claudespaces.host_config.GLOBAL_CONFIG_PATH", cfg)
    result = load_host_bridge()
    assert result["operations"]["notify"]["command"] == "custom-notify {msg}"


def test_custom_port_is_loaded(tmp_path, monkeypatch):
    cfg = tmp_path / "claudespaces.yaml"
    cfg.write_text("host_bridge:\n  port: 9999\n")
    monkeypatch.setattr("claudespaces.host_config.GLOBAL_CONFIG_PATH", cfg)
    result = load_host_bridge()
    assert result["port"] == 9999


def test_overrides_manifest_extracts_override_ops():
    operations = {
        "notify": {
            "command": "notify-send {s}",
            "args": ["s"],
            "async": True,
            "override": "notify-send",
        },
        "run": {"command": "run {cmd}", "args": ["cmd"]},
    }
    result = overrides_manifest(operations)
    assert result == {"notify-send": "notify"}


def test_overrides_manifest_empty_when_no_overrides():
    operations = {"run": {"command": "run {cmd}", "args": ["cmd"]}}
    result = overrides_manifest(operations)
    assert result == {}
```

- [ ] **Step 2: Run tests to confirm they fail**

```
.venv/bin/pytest tests/test_host_config.py -v
```
Expected: `ModuleNotFoundError: No module named 'claudespaces.host_config'`

- [ ] **Step 3: Implement `host_config.py`**

```python
# claudespaces/host_config.py
import json
from pathlib import Path

import yaml

from claudespaces.config import GLOBAL_CONFIG_PATH

DEFAULT_PORT = 7731
SHIMS_PATH = Path.home() / ".claudespaces" / "shims.json"

_BUILTIN_OPERATIONS: dict = {
    "notify": {
        "command": "notify-send {summary} {body}",
        "args": ["summary", "body"],
        "async": True,
        "override": "notify-send",
    }
}


def load_host_bridge() -> dict:
    """Return {"port": int, "operations": dict} merged from builtins and user config."""
    if GLOBAL_CONFIG_PATH.exists():
        with open(GLOBAL_CONFIG_PATH) as f:
            global_cfg = yaml.safe_load(f) or {}
    else:
        global_cfg = {}

    bridge_cfg = global_cfg.get("host_bridge", {})
    port = bridge_cfg.get("port", DEFAULT_PORT)

    operations = dict(_BUILTIN_OPERATIONS)
    operations.update(bridge_cfg.get("operations", {}))

    return {"port": port, "operations": operations}


def overrides_manifest(operations: dict) -> dict:
    """Return {binary_name: op_name} for operations that declare an override."""
    return {
        op["override"]: name
        for name, op in operations.items()
        if "override" in op
    }


def write_shims(operations: dict) -> None:
    """Write the shims manifest to SHIMS_PATH for bind-mounting into containers."""
    SHIMS_PATH.parent.mkdir(parents=True, exist_ok=True)
    manifest = overrides_manifest(operations)
    SHIMS_PATH.write_text(json.dumps(manifest, indent=2))
```

- [ ] **Step 4: Run tests to confirm they pass**

```
.venv/bin/pytest tests/test_host_config.py -v
```
Expected: all 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add claudespaces/host_config.py tests/test_host_config.py
git commit -m "feat: add host_config module for host bridge config loading"
```

---

## Task 2: `host_server.py` — HTTP handler and server lifecycle

**Files:**
- Create: `claudespaces/host_server.py`
- Create: `tests/test_host_server.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_host_server.py
import json
import subprocess
import socket
from unittest.mock import MagicMock, patch, call
from pathlib import Path
import pytest
from claudespaces.host_server import handle_run, is_running, stop_server_if_last

OPERATIONS = {
    "notify": {
        "command": "notify-send {summary} {body}",
        "args": ["summary", "body"],
        "async": True,
        "override": "notify-send",
    },
    "echo": {
        "command": "echo {msg}",
        "args": ["msg"],
    },
}


def test_unknown_op_returns_400():
    code, body = handle_run("nope", {}, OPERATIONS)
    assert code == 400
    assert "error" in body


def test_async_op_returns_ok_without_waiting():
    with patch("claudespaces.host_server.subprocess.Popen") as mock_popen:
        code, body = handle_run("notify", {"summary": "hi", "body": "there"}, OPERATIONS)
    assert code == 200
    assert body == {"status": "ok"}
    mock_popen.assert_called_once()


def test_async_op_builds_correct_command():
    with patch("claudespaces.host_server.subprocess.Popen") as mock_popen:
        handle_run("notify", {"summary": "title", "body": "message"}, OPERATIONS)
    cmd = mock_popen.call_args[0][0]
    assert cmd == ["notify-send", "title", "message"]


def test_async_op_with_positional_args_maps_by_order():
    with patch("claudespaces.host_server.subprocess.Popen") as mock_popen:
        handle_run("notify", ["title", "message"], OPERATIONS)
    cmd = mock_popen.call_args[0][0]
    assert cmd == ["notify-send", "title", "message"]


def test_sync_op_returns_stdout_stderr_exit_code():
    mock_result = MagicMock()
    mock_result.stdout = "hello\n"
    mock_result.stderr = ""
    mock_result.returncode = 0
    with patch("claudespaces.host_server.subprocess.run", return_value=mock_result):
        code, body = handle_run("echo", {"msg": "hello"}, OPERATIONS)
    assert code == 200
    assert body["stdout"] == "hello\n"
    assert body["stderr"] == ""
    assert body["exit_code"] == 0


def test_sync_op_mirrors_nonzero_exit_code():
    mock_result = MagicMock()
    mock_result.stdout = ""
    mock_result.stderr = "not found\n"
    mock_result.returncode = 127
    with patch("claudespaces.host_server.subprocess.run", return_value=mock_result):
        code, body = handle_run("echo", {"msg": "x"}, OPERATIONS)
    assert body["exit_code"] == 127


def test_is_running_returns_true_when_port_open(unused_tcp_port):
    with socket.socket() as srv:
        srv.bind(("127.0.0.1", unused_tcp_port))
        srv.listen(1)
        assert is_running(unused_tcp_port) is True


def test_is_running_returns_false_when_port_closed():
    # find a port that is definitely not in use
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    assert is_running(port) is False


def test_stop_server_if_last_kills_pid(tmp_path, monkeypatch):
    pid_file = tmp_path / "host_bridge.pid"
    pid_file.write_text("99999")
    monkeypatch.setattr("claudespaces.host_server.PID_FILE", pid_file)

    ws_list = [{"name": "ws1", "status": "stopped"}]

    with patch("claudespaces.host_server.workspaces.all_workspaces", return_value=ws_list), \
         patch("claudespaces.host_server.os.kill") as mock_kill:
        stop_server_if_last("ws1")

    mock_kill.assert_called_once_with(99999, 15)  # SIGTERM
    assert not pid_file.exists()


def test_stop_server_if_last_leaves_server_when_others_running(tmp_path, monkeypatch):
    pid_file = tmp_path / "host_bridge.pid"
    pid_file.write_text("99999")
    monkeypatch.setattr("claudespaces.host_server.PID_FILE", pid_file)

    ws_list = [
        {"name": "ws1", "status": "stopped"},
        {"name": "ws2", "status": "running"},
    ]

    with patch("claudespaces.host_server.workspaces.all_workspaces", return_value=ws_list), \
         patch("claudespaces.host_server.os.kill") as mock_kill:
        stop_server_if_last("ws1")

    mock_kill.assert_not_called()
    assert pid_file.exists()
```

> **Note:** `unused_tcp_port` is a pytest fixture. Add this to `tests/conftest.py` (create it if it doesn't exist):
> ```python
> import socket
> import pytest
>
> @pytest.fixture
> def unused_tcp_port():
>     with socket.socket() as s:
>         s.bind(("127.0.0.1", 0))
>         return s.getsockname()[1]
> ```

- [ ] **Step 2: Run tests to confirm they fail**

```
.venv/bin/pytest tests/test_host_server.py -v
```
Expected: `ModuleNotFoundError: No module named 'claudespaces.host_server'`

- [ ] **Step 3: Create `tests/conftest.py`**

```python
# tests/conftest.py
import socket
import pytest


@pytest.fixture
def unused_tcp_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
```

- [ ] **Step 4: Implement `host_server.py`**

```python
# claudespaces/host_server.py
import json
import os
import shlex
import signal
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from claudespaces import workspaces

PID_FILE = Path.home() / ".claudespaces" / "host_bridge.pid"


def handle_run(op_name: str, args, operations: dict) -> tuple[int, dict]:
    """Core request handler logic — returns (status_code, response_dict)."""
    if op_name not in operations:
        return 400, {"error": f"unknown operation: {op_name!r}"}

    op = operations[op_name]
    cmd_parts = shlex.split(op["command"])

    if isinstance(args, list):
        named = dict(zip(op.get("args", []), args))
    else:
        named = args

    cmd = [part.format_map(named) for part in cmd_parts]

    if op.get("async", False):
        subprocess.Popen(
            cmd,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return 200, {"status": "ok"}

    result = subprocess.run(cmd, capture_output=True, text=True)
    return 200, {
        "stdout": result.stdout,
        "stderr": result.stderr,
        "exit_code": result.returncode,
    }


def _make_handler(operations: dict):
    class BridgeHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_POST(self):
            if self.path != "/run":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
            code, response = handle_run(
                body.get("op", ""), body.get("args", {}), operations
            )
            payload = json.dumps(response).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return BridgeHandler


def run_server(port: int, operations: dict) -> None:
    server = HTTPServer(("127.0.0.1", port), _make_handler(operations))
    server.serve_forever()


def is_running(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def start_server() -> None:
    """Spawn the bridge server as a background process and record its PID."""
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(
        [sys.executable, "-m", "claudespaces.host_server"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    PID_FILE.write_text(str(proc.pid))


def stop_server_if_last(stopped_name: str) -> None:
    """Kill the bridge if no workspaces other than stopped_name are still running."""
    remaining = [
        w for w in workspaces.all_workspaces()
        if w["name"] != stopped_name and w["status"] == "running"
    ]
    if remaining:
        return
    if not PID_FILE.exists():
        return
    pid = int(PID_FILE.read_text().strip())
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    PID_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    from claudespaces.host_config import load_host_bridge
    bridge = load_host_bridge()
    run_server(bridge["port"], bridge["operations"])
```

- [ ] **Step 5: Run tests to confirm they pass**

```
.venv/bin/pytest tests/test_host_server.py -v
```
Expected: all 10 tests PASS

- [ ] **Step 6: Run full test suite to confirm no regressions**

```
.venv/bin/pytest -v
```
Expected: all tests PASS

- [ ] **Step 7: Commit**

```bash
git add claudespaces/host_server.py tests/test_host_server.py tests/conftest.py
git commit -m "feat: add host_server module with HTTP handler and server lifecycle"
```

---

## Task 3: `claudespaces-host` — in-container client script

**Files:**
- Create: `claudespaces/support/bin/claudespaces-host`

This script is bind-mounted into containers at `/claudespaces/bin/claudespaces-host`. It uses only Python stdlib and `curl` (both available on Ubuntu 24.04). No unit tests — behaviour is covered by integration.

- [ ] **Step 1: Create the script**

```python
#!/usr/bin/env python3
# claudespaces/support/bin/claudespaces-host
import json
import os
import sys
import urllib.error
import urllib.request

PORT = int(os.environ.get("CLAUDESPACES_HOST_PORT", "7731"))
URL = f"http://host.docker.internal:{PORT}/run"


def main():
    if len(sys.argv) < 2:
        print("Usage: claudespaces-host <op> [--key val ...] | [arg ...]", file=sys.stderr)
        sys.exit(1)

    op = sys.argv[1]
    remaining = sys.argv[2:]

    if remaining and remaining[0].startswith("--"):
        args: dict | list = {}
        i = 0
        while i < len(remaining):
            if remaining[i].startswith("--") and i + 1 < len(remaining):
                key = remaining[i][2:]
                args[key] = remaining[i + 1]  # type: ignore[index]
                i += 2
            else:
                print(f"Invalid argument: {remaining[i]}", file=sys.stderr)
                sys.exit(1)
    else:
        args = remaining

    payload = json.dumps({"op": op, "args": args}).encode()
    req = urllib.request.Request(
        URL,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            body = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = json.loads(e.read())
        print(f"Error: {body.get('error', 'unknown error')}", file=sys.stderr)
        sys.exit(1)
    except OSError:
        print("host bridge is not running", file=sys.stderr)
        sys.exit(1)

    if "status" in body:
        sys.exit(0)

    stdout = body.get("stdout", "")
    stderr = body.get("stderr", "")
    if stdout:
        sys.stdout.write(stdout)
    if stderr:
        sys.stderr.write(stderr)
    sys.exit(body.get("exit_code", 0))


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x claudespaces/support/bin/claudespaces-host
```

- [ ] **Step 3: Add it to `pyproject.toml` package data**

In `pyproject.toml`, update `[tool.setuptools.package-data]`:
```toml
[tool.setuptools.package-data]
claudespaces = ["Dockerfile.base", "support/bin/entrypoint.sh", "support/bin/claudespaces-host"]
```

- [ ] **Step 4: Reinstall the package so the new file is included**

```
pip install -e ".[dev]"
```

- [ ] **Step 5: Commit**

```bash
git add claudespaces/support/bin/claudespaces-host pyproject.toml
git commit -m "feat: add claudespaces-host client script for container-to-host calls"
```

---

## Task 4: `Dockerfile.base` — bake `claudespaces-host` into the image

**Files:**
- Modify: `claudespaces/Dockerfile.base`

The script is also bind-mounted at runtime (Task 5), so this just provides a fallback in case the bind mount is absent.

- [ ] **Step 1: Update `Dockerfile.base`**

Add these lines after the existing `COPY support/bin/entrypoint.sh` block:

```dockerfile
RUN mkdir -p /claudespaces/bin

COPY support/bin/claudespaces-host /claudespaces/bin/claudespaces-host

RUN chmod +x /claudespaces/bin/claudespaces-host
```

The full updated file:

```dockerfile
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99-sandbox

RUN apt update && apt install -y \
  curl \
  && apt clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://claude.ai/install.sh | bash

RUN mkdir -p /workspace /claudespaces /claudespaces/bin
WORKDIR /workspace

COPY support/bin/entrypoint.sh /claudespaces/entrypoint.sh
COPY support/bin/claudespaces-host /claudespaces/bin/claudespaces-host

RUN chmod +x /claudespaces/entrypoint.sh /claudespaces/bin/claudespaces-host

ENTRYPOINT ["sleep", "infinity"]
```

- [ ] **Step 2: Commit**

```bash
git add claudespaces/Dockerfile.base
git commit -m "feat(dockerfile): add claudespaces-host to container image"
```

---

## Task 5: `container.py` — add shims and `claudespaces-host` mounts

**Files:**
- Modify: `claudespaces/container.py`
- Modify: `tests/test_container.py`

- [ ] **Step 1: Read existing container tests to understand the pattern**

```
.venv/bin/pytest tests/test_container.py -v
```
Note how `create_container` is tested — the pattern is to call it with a mock docker client and inspect `containers.create` call args.

- [ ] **Step 2: Add failing tests**

Open `tests/test_container.py` and add these tests at the bottom:

```python
def test_create_container_mounts_shims_when_file_exists(tmp_path, mocker):
    mock_client = MagicMock()
    mock_client.containers.create.return_value = MagicMock(id="abc")

    shims_path = tmp_path / "shims.json"
    shims_path.write_text('{"notify-send": "notify"}')
    mocker.patch("claudespaces.container.SHIMS_PATH", shims_path)

    host_script = tmp_path / "claudespaces-host"
    host_script.write_text("#!/usr/bin/env python3")
    mocker.patch("claudespaces.container._CLAUDESPACES_HOST_SRC", host_script)

    state_dir = tmp_path / "state"
    state_dir.mkdir()
    (state_dir / "projects").mkdir()
    (state_dir / "claude.json").write_text("{}")

    container.create_container(mock_client, "myimage", [str(tmp_path)], state_dir)

    mounts = mock_client.containers.create.call_args.kwargs["mounts"]
    targets = [m["Target"] for m in mounts]
    assert "/claudespaces/shims.json" in targets


def test_create_container_skips_shims_when_file_absent(tmp_path, mocker):
    mock_client = MagicMock()
    mock_client.containers.create.return_value = MagicMock(id="abc")

    mocker.patch("claudespaces.container.SHIMS_PATH", tmp_path / "nonexistent.json")
    mocker.patch("claudespaces.container._CLAUDESPACES_HOST_SRC", tmp_path / "nonexistent")

    state_dir = tmp_path / "state"
    state_dir.mkdir()
    (state_dir / "projects").mkdir()
    (state_dir / "claude.json").write_text("{}")

    container.create_container(mock_client, "myimage", [str(tmp_path)], state_dir)

    mounts = mock_client.containers.create.call_args.kwargs["mounts"]
    targets = [m["Target"] for m in mounts]
    assert "/claudespaces/shims.json" not in targets


def test_create_container_injects_host_port_env(tmp_path, mocker):
    mock_client = MagicMock()
    mock_client.containers.create.return_value = MagicMock(id="abc")

    mocker.patch("claudespaces.container.SHIMS_PATH", tmp_path / "nope.json")
    mocker.patch("claudespaces.container._CLAUDESPACES_HOST_SRC", tmp_path / "nope")

    state_dir = tmp_path / "state"
    state_dir.mkdir()
    (state_dir / "projects").mkdir()
    (state_dir / "claude.json").write_text("{}")

    container.create_container(mock_client, "myimage", [str(tmp_path)], state_dir, host_port=9999)

    env = mock_client.containers.create.call_args.kwargs["environment"]
    assert env["CLAUDESPACES_HOST_PORT"] == "9999"
```

> **Note:** You'll need to check `tests/test_container.py` for the existing import of `container` and how `MagicMock` is set up for `containers.create`. The existing tests use `mock_client.containers.create.return_value = MagicMock(id="cid")` — follow that pattern.

- [ ] **Step 3: Run tests to confirm they fail**

```
.venv/bin/pytest tests/test_container.py -v -k "shims or host_port"
```
Expected: FAIL (attribute errors or assertion errors — the mounts aren't there yet)

- [ ] **Step 4: Update `container.py`**

Add imports at the top:
```python
from claudespaces.host_config import DEFAULT_PORT, SHIMS_PATH
```

Add this constant near the top (after the existing `CONTAINER_USER`):
```python
_CLAUDESPACES_HOST_SRC = Path(__file__).parent / "support" / "bin" / "claudespaces-host"
```

Change the `create_container` signature to accept an optional `host_port`:
```python
def create_container(docker_client, image: str, dirs: list[str], state_dir: Path, host_port: int = DEFAULT_PORT) -> str:
```

Add these mounts inside `create_container`, after the existing `host_mounts` block (before `docker_client.containers.create`):

```python
    if SHIMS_PATH.exists():
        mounts.append(Mount(
            target="/claudespaces/shims.json",
            source=str(SHIMS_PATH),
            type="bind",
            read_only=True,
        ))

    if _CLAUDESPACES_HOST_SRC.exists():
        mounts.append(Mount(
            target="/claudespaces/bin/claudespaces-host",
            source=str(_CLAUDESPACES_HOST_SRC),
            type="bind",
            read_only=True,
        ))
```

Update the `environment` dict in `docker_client.containers.create(...)`:
```python
    container = docker_client.containers.create(
        image=image,
        tty=True,
        stdin_open=True,
        user=CONTAINER_USER,
        working_dir="/workspace",
        mounts=mounts,
        environment={
            "IS_SANDBOX": "1",
            "HOST_HOME": str(Path.home()),
            "CLAUDESPACES_HOST_PORT": str(host_port),
        },
    )
```

- [ ] **Step 5: Run tests to confirm they pass**

```
.venv/bin/pytest tests/test_container.py -v
```
Expected: all tests PASS

- [ ] **Step 6: Commit**

```bash
git add claudespaces/container.py tests/test_container.py
git commit -m "feat(container): mount shims.json and claudespaces-host, inject HOST_PORT env var"
```

---

## Task 6: `entrypoint.sh` — PATH and shim injection

**Files:**
- Modify: `claudespaces/support/bin/entrypoint.sh`

- [ ] **Step 1: Update `entrypoint.sh`**

Add the PATH export and shim injection block between the existing config copy section and the `exec claude` line:

```bash
#!/bin/bash
set -e

mkdir -p ~/.claude

if [ -f /claudespaces/host/settings.json ]; then
    cp /claudespaces/host/settings.json ~/.claude/settings.json
fi

if [ -d /claudespaces/host/plugins ]; then
    mkdir -p ~/.claude/plugins/
    cp -r /claudespaces/host/plugins/. ~/.claude/plugins/
    if [ -n "$HOST_HOME" ]; then
        for f in ~/.claude/plugins/installed_plugins.json ~/.claude/plugins/known_marketplaces.json; do
            if [ -f "$f" ]; then
                sed -i "s|${HOST_HOME}/.claude|${HOME}/.claude|g" "$f"
            fi
        done
    fi
fi

if [ -f /claudespaces/host/credentials.json ]; then
    cp /claudespaces/host/credentials.json ~/.claude/.credentials.json
fi

# Add claudespaces bin to PATH so claudespaces-host is always findable
export PATH="/claudespaces/bin:$PATH"

# Inject shims for host bridge overrides
if [ -f /claudespaces/shims.json ]; then
    python3 - <<'PYEOF'
import json, os, stat

with open("/claudespaces/shims.json") as f:
    shims = json.load(f)

for binary, op_name in shims.items():
    path = f"/usr/local/bin/{binary}"
    orig = f"{path}.orig"
    if os.path.exists(path) and not os.path.islink(path):
        os.rename(path, orig)
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\nclaudespaces-host {op_name} \"$@\"\n")
    os.chmod(path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
PYEOF
fi

IS_SANDBOX=1 exec /root/.local/bin/claude \
    --allow-dangerously-skip-permissions \
    --dangerously-skip-permissions \
    --enable-auto-mode \
    --add-dir / "$@"
```

- [ ] **Step 2: Commit**

```bash
git add claudespaces/support/bin/entrypoint.sh
git commit -m "feat(entrypoint): add PATH for claudespaces-host and inject bridge shims"
```

---

## Task 7: `cli.py` — server lifecycle and shims writing

**Files:**
- Modify: `claudespaces/cli.py`
- Modify: `tests/test_cli.py`

- [ ] **Step 1: Write the failing tests**

Add these tests to `tests/test_cli.py`:

```python
# Add to existing imports at top of test_cli.py
# (no new imports needed — existing fixtures cover everything)


@pytest.fixture
def mock_host_server(mocker):
    m = mocker.patch("claudespaces.cli.host_server")
    m.is_running.return_value = False
    return m


@pytest.fixture
def mock_host_config(mocker):
    m = mocker.patch("claudespaces.cli.host_config")
    m.load_host_bridge.return_value = {"port": 7731, "operations": {}}
    m.overrides_manifest.return_value = {}
    m.write_shims.return_value = None
    m.DEFAULT_PORT = 7731
    return m


def test_start_spawns_bridge_when_port_free(
    mock_docker, mock_workspaces, mock_container, mock_host_server, mock_host_config
):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-ws",
        "container_id": "abc",
        "image": "img",
        "status": "stopped",
        "dirs": ["/some/dir"],
    }
    mock_workspaces.state_dir.return_value.exists.return_value = True
    mock_host_server.is_running.return_value = False

    runner.invoke(app, ["start", "my-ws"])

    mock_host_server.start_server.assert_called_once()


def test_start_skips_bridge_when_already_running(
    mock_docker, mock_workspaces, mock_container, mock_host_server, mock_host_config
):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-ws",
        "container_id": "abc",
        "image": "img",
        "status": "stopped",
        "dirs": ["/some/dir"],
    }
    mock_workspaces.state_dir.return_value.exists.return_value = True
    mock_host_server.is_running.return_value = True

    runner.invoke(app, ["start", "my-ws"])

    mock_host_server.start_server.assert_not_called()


def test_stop_kills_bridge_when_last_workspace(
    mock_docker, mock_workspaces, mock_container, mock_host_server, mock_host_config
):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-ws",
        "container_id": "abc",
        "image": "img",
        "status": "running",
        "dirs": ["/some/dir"],
    }

    runner.invoke(app, ["stop", "my-ws"])

    mock_host_server.stop_server_if_last.assert_called_once_with("my-ws")
```

- [ ] **Step 2: Run tests to confirm they fail**

```
.venv/bin/pytest tests/test_cli.py -v -k "bridge"
```
Expected: FAIL — `cli` has no `host_server` or `host_config` attributes yet

- [ ] **Step 3: Update `cli.py`**

Add imports near the top (after the existing `from claudespaces import ...` line):

```python
from claudespaces import config, container, host_config, host_server, image, workspaces
```

Add a helper function after `_now_utc`:

```python
def _start_bridge(port: int) -> None:
    if not host_server.is_running(port):
        host_server.start_server()
```

In the `new` command, add shims writing before `create_container`. Find this block:

```python
    try:
        container_id = container.create_container(docker_client, resolved_image, resolved_dirs, state_dir=sd)
```

And insert before it:

```python
    bridge = host_config.load_host_bridge()
    host_config.write_shims(bridge["operations"])
```

Also update the `create_container` call to pass `host_port`:

```python
    try:
        container_id = container.create_container(
            docker_client, resolved_image, resolved_dirs, state_dir=sd, host_port=bridge["port"]
        )
```

In the `new` command's `if start:` block, add bridge start before attaching and bridge stop in the finally:

```python
    if start:
        _start_bridge(bridge["port"])
        workspaces.update_workspace(name, status="running")
        try:
            container.attach_container(container_id)
        except KeyboardInterrupt:
            pass
        finally:
            workspaces.update_workspace(name, status="stopped", last_used_at=_now_utc())
            container.stop_container(docker_client, container_id)
            host_server.stop_server_if_last(name)
```

In the `start` command, add bridge start before attaching and bridge stop in the finally. Find:

```python
    workspaces.update_workspace(name, status="running")
    try:
        container.attach_container(workspace["container_id"])
    except KeyboardInterrupt:
        pass
    finally:
        workspaces.update_workspace(name, status="stopped", last_used_at=_now_utc())
        container.stop_container(docker_client, workspace["container_id"])
```

And replace with:

```python
    bridge = host_config.load_host_bridge()
    host_config.write_shims(bridge["operations"])
    _start_bridge(bridge["port"])
    workspaces.update_workspace(name, status="running")
    try:
        container.attach_container(workspace["container_id"])
    except KeyboardInterrupt:
        pass
    finally:
        workspaces.update_workspace(name, status="stopped", last_used_at=_now_utc())
        container.stop_container(docker_client, workspace["container_id"])
        host_server.stop_server_if_last(name)
```

In the `stop` command, add bridge teardown. Find:

```python
    workspaces.update_workspace(name, status="stopped")
    typer.echo(f"Stopped workspace '{name}'.")
```

And replace with:

```python
    workspaces.update_workspace(name, status="stopped")
    host_server.stop_server_if_last(name)
    typer.echo(f"Stopped workspace '{name}'.")
```

- [ ] **Step 4: Run the new tests**

```
.venv/bin/pytest tests/test_cli.py -v -k "bridge"
```
Expected: all 3 new tests PASS

- [ ] **Step 5: Run the full test suite**

```
.venv/bin/pytest -v
```
Expected: all tests PASS

- [ ] **Step 6: Commit**

```bash
git add claudespaces/cli.py tests/test_cli.py
git commit -m "feat(cli): start/stop host bridge server alongside workspace lifecycle"
```

---

## Task 8: End-to-end smoke test

No automated test — verify manually that the bridge works in a real container.

- [ ] **Step 1: Rebuild the base image**

```bash
.venv/bin/claudespaces new /tmp/bridge-test --named bridge-test
```

- [ ] **Step 2: Start the workspace and verify the bridge starts**

```bash
.venv/bin/claudespaces start bridge-test
```

In another terminal, confirm the server is up:
```bash
curl -s -X POST http://localhost:7731/run \
  -H "Content-Type: application/json" \
  -d '{"op":"unknown","args":{}}' | cat
```
Expected: `{"error": "unknown operation: 'unknown'"}`

- [ ] **Step 3: Inside the container, call the bridge explicitly**

```bash
claudespaces-host notify --summary "Test" --body "Bridge works"
```
Expected: desktop notification appears on the host.

- [ ] **Step 4: Verify `notify-send` shim (if override is configured)**

Add to `~/.config/claudespaces/claudespaces.yaml`:
```yaml
host_bridge:
  operations:
    notify:
      override: notify-send
```

Exit and re-start the workspace. Inside the container:
```bash
notify-send "Shim test" "Works transparently"
```
Expected: notification appears on host; `which notify-send` shows `/usr/local/bin/notify-send` (the shim).

- [ ] **Step 5: Clean up**

```bash
.venv/bin/claudespaces remove bridge-test
```

---

## Summary

| Task | New files | Modified files |
|------|-----------|----------------|
| 1 | `host_config.py`, `test_host_config.py` | — |
| 2 | `host_server.py`, `test_host_server.py`, `conftest.py` | — |
| 3 | `support/bin/claudespaces-host` | `pyproject.toml` |
| 4 | — | `Dockerfile.base` |
| 5 | — | `container.py`, `test_container.py` |
| 6 | — | `entrypoint.sh` |
| 7 | — | `cli.py`, `test_cli.py` |
| 8 | — | — (manual smoke test) |
