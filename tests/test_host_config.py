import yaml
import pytest
from claudespaces.host_config import (
    load_host_bridge,
    overrides_manifest,
    write_shims,
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


def test_write_shims_creates_manifest_file(tmp_path, monkeypatch):
    shims_path = tmp_path / "shims.json"
    monkeypatch.setattr("claudespaces.host_config.SHIMS_PATH", shims_path)

    operations = {
        "notify": {
            "command": "notify-send {s}",
            "args": ["s"],
            "async": True,
            "override": "notify-send",
        },
        "run": {"command": "run {cmd}", "args": ["cmd"]},
    }
    write_shims(operations)

    import json
    assert shims_path.exists()
    data = json.loads(shims_path.read_text())
    assert data == {"notify-send": "notify"}
