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
