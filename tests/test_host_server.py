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
