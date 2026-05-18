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
