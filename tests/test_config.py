import pytest
from pathlib import Path
from claudespaces import config
from claudespaces.config import load_config, _parse_mount


@pytest.fixture(autouse=True)
def no_global_config(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "GLOBAL_CONFIG_PATH", tmp_path / "global.yaml")


# --- local config ---

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


# --- global config ---

def test_global_dockerfile_exposed_as_global_dockerfile(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("dockerfile: ~/.config/claudespaces/Dockerfile\n")
    monkeypatch.setattr(config, "GLOBAL_CONFIG_PATH", global_cfg)
    result = load_config(str(tmp_path))
    assert result["global_dockerfile"] == "~/.config/claudespaces/Dockerfile"
    assert "dockerfile" not in result


def test_global_raises_on_both_image_and_dockerfile(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("image: foo\ndockerfile: ./Dockerfile\n")
    monkeypatch.setattr(config, "GLOBAL_CONFIG_PATH", global_cfg)
    with pytest.raises(ValueError, match="mutually exclusive"):
        load_config(str(tmp_path))


def test_local_image_overrides_global_image(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("image: ubuntu:24.04\n")
    monkeypatch.setattr(config, "GLOBAL_CONFIG_PATH", global_cfg)
    (tmp_path / "claudespaces.yml").write_text("image: debian:12\n")
    assert load_config(str(tmp_path))["image"] == "debian:12"


def test_global_image_used_when_no_local_image(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("image: debian:12\n")
    monkeypatch.setattr(config, "GLOBAL_CONFIG_PATH", global_cfg)
    assert load_config(str(tmp_path))["image"] == "debian:12"


def test_global_dockerfile_and_local_dockerfile_both_present(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("dockerfile: ~/.config/claudespaces/Dockerfile\n")
    monkeypatch.setattr(config, "GLOBAL_CONFIG_PATH", global_cfg)
    (tmp_path / "claudespaces.yml").write_text("dockerfile: ./Dockerfile\n")
    result = load_config(str(tmp_path))
    assert result["global_dockerfile"] == "~/.config/claudespaces/Dockerfile"
    assert result["dockerfile"] == "./Dockerfile"


def test_global_dockerfile_and_local_image_both_present(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("dockerfile: ~/.config/claudespaces/Dockerfile\n")
    monkeypatch.setattr(config, "GLOBAL_CONFIG_PATH", global_cfg)
    (tmp_path / "claudespaces.yml").write_text("image: debian:12\n")
    result = load_config(str(tmp_path))
    assert result["global_dockerfile"] == "~/.config/claudespaces/Dockerfile"
    assert result["image"] == "debian:12"


def test_directories_merged_from_global_and_local(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("directories:\n  - ~/global-proj\n")
    monkeypatch.setattr(config, "GLOBAL_CONFIG_PATH", global_cfg)
    (tmp_path / "claudespaces.yml").write_text("directories:\n  - ~/local-proj\n")
    assert load_config(str(tmp_path))["directories"] == ["~/global-proj", "~/local-proj"]


# --- additional-mounts ---

def test_parse_mount_src_dst():
    m = _parse_mount("/host/path:/container/path")
    assert m == {"source": "/host/path", "target": "/container/path", "read_only": False}

def test_parse_mount_src_dst_rw():
    m = _parse_mount("/host/path:/container/path:rw")
    assert m == {"source": "/host/path", "target": "/container/path", "read_only": False}

def test_parse_mount_src_dst_ro():
    m = _parse_mount("/host/path:/container/path:ro")
    assert m == {"source": "/host/path", "target": "/container/path", "read_only": True}

def test_parse_mount_invalid():
    with pytest.raises(ValueError, match="invalid mount"):
        _parse_mount("/only-one-part")

def test_additional_mounts_local_only(tmp_path):
    cfg_file = tmp_path / "claudespaces.yml"
    cfg_file.write_text("additional-mounts:\n  - /src:/dst:ro\n")
    result = load_config(cwd=str(tmp_path))
    assert result["additional_mounts"] == [{"source": "/src", "target": "/dst", "read_only": True}]

def test_additional_mounts_global_only(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("additional-mounts:\n  - /g:/cg:rw\n")
    monkeypatch.setattr("claudespaces.config.GLOBAL_CONFIG_PATH", global_cfg)
    result = load_config(cwd=str(tmp_path))
    assert result["additional_mounts"] == [{"source": "/g", "target": "/cg", "read_only": False}]

def test_additional_mounts_merged(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("additional-mounts:\n  - /g:/cg\n")
    monkeypatch.setattr("claudespaces.config.GLOBAL_CONFIG_PATH", global_cfg)
    local_cfg = tmp_path / "claudespaces.yml"
    local_cfg.write_text("additional-mounts:\n  - /l:/cl:ro\n")
    result = load_config(cwd=str(tmp_path))
    assert result["additional_mounts"] == [
        {"source": "/g", "target": "/cg", "read_only": False},
        {"source": "/l", "target": "/cl", "read_only": True},
    ]

def test_additional_mounts_collision_raises(tmp_path, monkeypatch):
    global_cfg = tmp_path / "global.yaml"
    global_cfg.write_text("additional-mounts:\n  - /g:/shared\n")
    monkeypatch.setattr("claudespaces.config.GLOBAL_CONFIG_PATH", global_cfg)
    local_cfg = tmp_path / "claudespaces.yml"
    local_cfg.write_text("additional-mounts:\n  - /l:/shared\n")
    with pytest.raises(ValueError, match="/shared"):
        load_config(cwd=str(tmp_path))

def test_no_additional_mounts_key_absent(tmp_path):
    result = load_config(cwd=str(tmp_path))
    assert "additional_mounts" not in result
