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
def mock_sessions(mocker):
    m = mocker.patch("claudespaces.cli.sessions")
    m.get_sessions_for_dirs.return_value = []
    m.all_sessions.return_value = []
    m.heal_running_sessions.return_value = None
    m.deduplicate_sessions.return_value = []
    m.generate_name.return_value = "bold-space"
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


def test_session_marked_stopped_and_container_stopped_after_attach(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    mock_sessions.get_sessions_for_dirs.return_value = []

    runner.invoke(app, [str(proj)])

    update_calls = mock_sessions.update_session.call_args_list
    assert any(
        call.kwargs.get("status") == "stopped" for call in update_calls
    )
    mock_container.stop_container.assert_called_once()


def test_existing_session_auto_attaches(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    existing = [{
        "id": "abc12345", "name": "bold-space", "dirs": [str(proj)],
        "container_id": "c1", "status": "stopped",
        "last_used_at": "2026-05-17T14:32:00Z",
    }]
    mock_sessions.get_sessions_for_dirs.return_value = existing

    runner.invoke(app, [str(proj)])

    mock_container.create_container.assert_not_called()
    mock_container.attach_container.assert_called_once_with("c1")


def test_deduplicate_sessions_called_on_startup(
    tmp_path, mock_docker, mock_sessions, mock_container, mock_image, mock_config
):
    proj = tmp_path / "proj"
    proj.mkdir()
    mock_sessions.get_sessions_for_dirs.return_value = []
    mock_sessions.deduplicate_sessions.return_value = []

    runner.invoke(app, [str(proj)])

    mock_sessions.deduplicate_sessions.assert_called_once()


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


def test_remove_running_session(mock_docker, mock_sessions, mock_container):
    mock_sessions.get_session_by_id.return_value = {
        "id": "abc12345", "name": "bold-space", "container_id": "c1", "status": "running"
    }
    result = runner.invoke(app, ["remove", "abc12345"])
    assert result.exit_code == 0
    mock_container.remove_container.assert_called_once()
    mock_sessions.remove_session.assert_called_once_with("abc12345")
    assert "Removed session bold-space" in result.output


def test_no_dirs_no_config_exits_1(mock_config):
    # CLI exits before Docker check; CWD has no claudespaces.yml so Path check is False naturally
    mock_config.load_config.return_value = {}
    result = runner.invoke(app, [])
    assert result.exit_code == 1
    assert "No directories specified" in result.output
