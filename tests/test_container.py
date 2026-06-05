import pytest
from unittest.mock import MagicMock, patch
import docker
from docker.types import Mount
import claudespaces.container as container
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


@pytest.fixture
def state_dir(tmp_path):
    sd = tmp_path / "state"
    sd.mkdir()
    (sd / "claude.json").write_text("{}")
    (sd / "projects").mkdir()
    return sd


def test_create_raises_on_basename_collision(client, tmp_path, state_dir):
    dir_a = tmp_path / "group1" / "myapp"
    dir_b = tmp_path / "group2" / "myapp"
    dir_a.mkdir(parents=True)
    dir_b.mkdir(parents=True)
    with pytest.raises(ValueError, match="basename"):
        create_container(client, "image", [str(dir_a), str(dir_b)], state_dir)


def test_create_mounts_user_dir_at_workspace_basename(client, tmp_path, state_dir):
    proj = tmp_path / "myproject"
    proj.mkdir()

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/workspace/myproject" in targets


def test_create_user_dir_mount_is_readwrite(client, tmp_path, state_dir):
    proj = tmp_path / "proj"
    proj.mkdir()

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    user_mount = next(m for m in kwargs["mounts"] if m["Target"] == "/workspace/proj")
    assert user_mount["ReadOnly"] is False


def test_create_sets_container_options(client, tmp_path, state_dir):
    proj = tmp_path / "proj"
    proj.mkdir()

    create_container(client, "claudespaces-base:ubuntu-24.04", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    assert kwargs["tty"] is True
    assert kwargs["stdin_open"] is True
    assert kwargs["working_dir"] == "/workspace"
    assert kwargs["user"] == "root"
    assert "command" not in kwargs


def test_create_sets_is_sandbox_env(client, tmp_path, state_dir):
    proj = tmp_path / "proj"
    proj.mkdir()

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    assert kwargs["environment"]["IS_SANDBOX"] == "1"


def test_create_returns_container_id(client, tmp_path, state_dir):
    proj = tmp_path / "proj"
    proj.mkdir()

    result = create_container(client, "image", [str(proj)], state_dir)

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


def test_create_mounts_state_claude_json_rw(client, tmp_path, state_dir):
    proj = tmp_path / "proj"
    proj.mkdir()

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    mount = next(m for m in kwargs["mounts"] if m["Target"] == "/root/.claude.json")
    assert mount["Source"] == str(state_dir / "claude.json")
    assert mount["ReadOnly"] is False


def test_create_mounts_state_projects_rw(client, tmp_path, state_dir):
    proj = tmp_path / "proj"
    proj.mkdir()

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    mount = next(m for m in kwargs["mounts"] if m["Target"] == "/root/.claude/projects")
    assert mount["Source"] == str(state_dir / "projects")
    assert mount["ReadOnly"] is False


def test_create_mounts_settings_json_when_present(client, tmp_path, state_dir, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    settings = fake_home / ".claude" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text("{}")

    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    mount = next(m for m in kwargs["mounts"] if m["Target"] == "/claudespaces/host/settings.json")
    assert mount["Source"] == str(settings)
    assert mount["ReadOnly"] is True


def test_create_mounts_plugins_when_present(client, tmp_path, state_dir, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    plugins = fake_home / ".claude" / "plugins"
    plugins.mkdir(parents=True)

    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    mount = next(m for m in kwargs["mounts"] if m["Target"] == "/claudespaces/host/plugins")
    assert mount["Source"] == str(plugins)
    assert mount["ReadOnly"] is True


def test_create_mounts_credentials_when_present(client, tmp_path, state_dir, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    credentials = fake_home / ".claude" / ".credentials.json"
    credentials.parent.mkdir(parents=True)
    credentials.write_text("{}")

    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    mount = next(m for m in kwargs["mounts"] if m["Target"] == "/claudespaces/host/credentials.json")
    assert mount["Source"] == str(credentials)
    assert mount["ReadOnly"] is True


def test_create_skips_host_mounts_when_absent(client, tmp_path, state_dir, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    fake_home.mkdir()  # no .claude dir or files inside

    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/claudespaces/host/settings.json" not in targets
    assert "/claudespaces/host/plugins" not in targets
    assert "/claudespaces/host/credentials.json" not in targets


def test_create_mounts_entrypoint_from_package(client, tmp_path, state_dir, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    entrypoint_mount = next(
        (m for m in kwargs["mounts"] if m["Target"] == "/claudespaces/entrypoint.sh"),
        None,
    )
    assert entrypoint_mount is not None, "entrypoint.sh should be bind-mounted"
    assert entrypoint_mount["ReadOnly"] is True
    assert entrypoint_mount["Source"].endswith("support/bin/entrypoint.sh")


def test_create_sets_host_home_env(client, tmp_path, state_dir, monkeypatch):
    proj = tmp_path / "proj"
    proj.mkdir()
    fake_home = tmp_path / "home"
    fake_home.mkdir()

    monkeypatch.setattr("claudespaces.container.Path.home", lambda: fake_home)

    create_container(client, "image", [str(proj)], state_dir)

    kwargs = client.containers.create.call_args.kwargs
    assert kwargs["environment"]["HOST_HOME"] == str(fake_home)


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


def test_create_container_adds_host_gateway(tmp_path, mocker):
    mock_client = MagicMock()
    mock_client.containers.create.return_value = MagicMock(id="abc")

    mocker.patch("claudespaces.container.SHIMS_PATH", tmp_path / "nope.json")
    mocker.patch("claudespaces.container._CLAUDESPACES_HOST_SRC", tmp_path / "nope")

    state_dir = tmp_path / "state"
    state_dir.mkdir()
    (state_dir / "projects").mkdir()
    (state_dir / "claude.json").write_text("{}")

    container.create_container(mock_client, "myimage", [str(tmp_path)], state_dir)

    extra_hosts = mock_client.containers.create.call_args.kwargs["extra_hosts"]
    assert extra_hosts == {"host.docker.internal": "host-gateway"}


def test_additional_mounts_appended(tmp_path):
    client = MagicMock()
    client.containers.create.return_value = MagicMock(id="abc123")
    extra = [
        {"source": "/host/docs", "target": "/docs", "read_only": True},
        {"source": "/host/scripts", "target": "/scripts", "read_only": False},
    ]
    create_container(client, "some-image", [], state_dir=tmp_path, additional_mounts=extra)
    kwargs = client.containers.create.call_args.kwargs
    mounts = kwargs["mounts"]
    docs = next(m for m in mounts if m["Target"] == "/docs")
    assert docs["Source"] == "/host/docs"
    assert docs["ReadOnly"] is True
    scripts = next(m for m in mounts if m["Target"] == "/scripts")
    assert scripts["Source"] == "/host/scripts"
    assert scripts["ReadOnly"] is False


def test_no_additional_mounts_default(tmp_path):
    client = MagicMock()
    client.containers.create.return_value = MagicMock(id="abc123")
    create_container(client, "some-image", [], state_dir=tmp_path)
    kwargs = client.containers.create.call_args.kwargs
    targets = [m["Target"] for m in kwargs["mounts"]]
    assert "/docs" not in targets
