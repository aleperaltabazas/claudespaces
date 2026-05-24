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
        create_container(client, "image", [str(dir_a), str(dir_b)])


def test_create_mounts_user_dir_at_workspace_basename(client, tmp_path):
    proj = tmp_path / "myproject"
    proj.mkdir()

    create_container(client, "image", [str(proj)])

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/workspace/myproject" in targets


def test_create_user_dir_mount_is_readwrite(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()

    create_container(client, "image", [str(proj)])

    kwargs = client.containers.create.call_args.kwargs
    user_mount = next(m for m in kwargs["mounts"] if m["Target"] == "/workspace/proj")
    assert user_mount["ReadOnly"] is False


def test_create_sets_container_options(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()

    create_container(client, "claudespaces-base:ubuntu-24.04", [str(proj)])

    kwargs = client.containers.create.call_args.kwargs
    assert kwargs["tty"] is True
    assert kwargs["stdin_open"] is True
    assert kwargs["working_dir"] == "/workspace"
    assert kwargs["user"] == "root"
    assert "command" not in kwargs


def test_create_sets_is_sandbox_env(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()

    create_container(client, "image", [str(proj)])

    kwargs = client.containers.create.call_args.kwargs
    assert kwargs["environment"]["IS_SANDBOX"] == "1"


def test_create_returns_container_id(client, tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()

    result = create_container(client, "image", [str(proj)])

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


def test_create_mounts_claude_dir_when_present(client, tmp_path, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    claude_dir = fake_home / ".claude"
    claude_dir.mkdir(parents=True)

    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)])

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/claudespaces/.claude" in targets
    claude_mount = next(m for m in kwargs["mounts"] if m["Target"] == "/claudespaces/.claude")
    assert claude_mount["ReadOnly"] is True


def test_create_mounts_claude_json_when_present(client, tmp_path, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    claude_json = fake_home / ".claude.json"
    claude_json.write_text("{}")

    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)])

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/claudespaces/.claude.json" in targets
    json_mount = next(m for m in kwargs["mounts"] if m["Target"] == "/claudespaces/.claude.json")
    assert json_mount["ReadOnly"] is True


def test_create_skips_claude_mounts_when_absent(client, tmp_path, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    fake_home.mkdir()  # no .claude or .claude.json inside

    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)])

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/claudespaces/.claude" not in targets
    assert "/claudespaces/.claude.json" not in targets
