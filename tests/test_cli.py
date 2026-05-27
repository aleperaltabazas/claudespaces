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
    m.state_dir.return_value.exists.return_value = False
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


def test_new_creates_state_dir(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    state = tmp_path / "state" / "bold-space"
    mock_workspaces.state_dir.return_value = state
    result = runner.invoke(app, ["new", str(proj)])
    assert result.exit_code == 0
    assert state.exists()
    assert state.is_dir()


def test_new_creates_claude_json(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    state = tmp_path / "state" / "bold-space"
    mock_workspaces.state_dir.return_value = state
    result = runner.invoke(app, ["new", str(proj)])
    assert result.exit_code == 0
    assert (state / "claude.json").exists()


def test_new_creates_projects_dir(
    tmp_path, mock_docker, mock_workspaces, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    state = tmp_path / "state" / "bold-space"
    mock_workspaces.state_dir.return_value = state
    result = runner.invoke(app, ["new", str(proj)])
    assert result.exit_code == 0
    assert (state / "projects").exists()
    assert (state / "projects").is_dir()


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


def test_remove_deletes_state_dir(tmp_path, mock_docker, mock_workspaces, mock_container):
    mock_workspaces.get_workspace_by_name.return_value = {
        "name": "my-game", "container_id": "c1", "status": "stopped",
    }
    state = tmp_path / "state" / "my-game"
    state.mkdir(parents=True)
    (state / "claude.json").write_text("{}")
    (state / "projects").mkdir()
    mock_workspaces.state_dir.return_value = state
    result = runner.invoke(app, ["remove", "my-game"])
    assert result.exit_code == 0
    assert not state.exists()


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
