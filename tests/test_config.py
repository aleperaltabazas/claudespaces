import pytest
from pathlib import Path
from claudespaces.config import load_config


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
