import pytest
from unittest.mock import MagicMock, call
import docker
from claudespaces.image import resolve_image


@pytest.fixture
def client():
    c = MagicMock()
    c.api.build.return_value = iter([])
    return c


# --- existing behaviour (no global dockerfile) ---

def test_default_returns_ubuntu_tag(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image(None, None, None, client)
    assert result.startswith("claudespaces-base:ubuntu-24.04-")


def test_named_image_derives_tag(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image("myrepo/img:tag", None, None, client)
    assert result.startswith("claudespaces-base:myrepo-img-tag-")


def test_named_image_colon_slash_replaced(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image("registry.io/org/image:v1.2", None, None, client)
    assert result.startswith("claudespaces-base:registry.io-org-image-v1.2-")


def test_missing_dockerfile_raises_file_not_found(client, tmp_path):
    with pytest.raises(FileNotFoundError):
        resolve_image(None, None, str(tmp_path / "Dockerfile"), client)


def test_cache_hit_skips_build(client):
    client.images.get.return_value = MagicMock()
    result = resolve_image(None, None, None, client)
    assert result.startswith("claudespaces-base:ubuntu-24.04-")
    client.api.build.assert_not_called()


def test_cache_miss_triggers_build(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, None, None, client)
    client.api.build.assert_called_once()
    kwargs = client.api.build.call_args.kwargs
    assert kwargs["tag"].startswith("claudespaces-base:ubuntu-24.04-")


def test_dockerfile_triggers_two_builds(client, tmp_path):
    dockerfile = tmp_path / "Dockerfile"
    dockerfile.write_text("FROM ubuntu:24.04\n")
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, None, str(dockerfile), client)
    assert client.api.build.call_count == 2


# --- global dockerfile ---

def test_missing_global_dockerfile_raises_file_not_found(client, tmp_path):
    with pytest.raises(FileNotFoundError, match="Global Dockerfile"):
        resolve_image(None, str(tmp_path / "Dockerfile.global"), None, client)


def test_global_dockerfile_cache_miss_triggers_two_builds(client, tmp_path):
    global_df = tmp_path / "Dockerfile.global"
    global_df.write_text("ARG BASE_IMAGE=ubuntu:24.04\nFROM ${BASE_IMAGE}\n")
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, str(global_df), None, client)
    assert client.api.build.call_count == 2


def test_global_dockerfile_built_with_base_image_arg(client, tmp_path):
    global_df = tmp_path / "Dockerfile.global"
    global_df.write_text("ARG BASE_IMAGE=ubuntu:24.04\nFROM ${BASE_IMAGE}\n")
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, str(global_df), None, client)
    first_call_kwargs = client.api.build.call_args_list[0].kwargs
    assert first_call_kwargs["buildargs"]["BASE_IMAGE"] == "ubuntu:24.04"


def test_global_dockerfile_uses_local_image_as_base(client, tmp_path):
    global_df = tmp_path / "Dockerfile.global"
    global_df.write_text("ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n")
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image("debian:12", str(global_df), None, client)
    first_call_kwargs = client.api.build.call_args_list[0].kwargs
    assert first_call_kwargs["buildargs"]["BASE_IMAGE"] == "debian:12"


def test_global_dockerfile_cache_hit_skips_global_build(client, tmp_path):
    global_df = tmp_path / "Dockerfile.global"
    global_df.write_text("ARG BASE_IMAGE=ubuntu:24.04\nFROM ${BASE_IMAGE}\n")

    def get_side_effect(tag):
        if tag.startswith("claudespaces-global:"):
            return MagicMock()
        raise docker.errors.ImageNotFound("not found")

    client.images.get.side_effect = get_side_effect
    resolve_image(None, str(global_df), None, client)
    assert client.api.build.call_count == 1
    kwargs = client.api.build.call_args.kwargs
    assert kwargs["tag"].startswith("claudespaces-base:")


def test_global_and_project_dockerfile_triggers_three_builds(client, tmp_path):
    global_df = tmp_path / "Dockerfile.global"
    global_df.write_text("ARG BASE_IMAGE=ubuntu:24.04\nFROM ${BASE_IMAGE}\n")
    project_df = tmp_path / "Dockerfile"
    project_df.write_text("ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n")
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, str(global_df), str(project_df), client)
    assert client.api.build.call_count == 3


def test_project_dockerfile_receives_global_output_as_base(client, tmp_path):
    global_df = tmp_path / "Dockerfile.global"
    global_df.write_text("ARG BASE_IMAGE=ubuntu:24.04\nFROM ${BASE_IMAGE}\n")
    project_df = tmp_path / "Dockerfile"
    project_df.write_text("ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n")
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, str(global_df), str(project_df), client)
    second_call_kwargs = client.api.build.call_args_list[1].kwargs
    assert second_call_kwargs["buildargs"]["BASE_IMAGE"].startswith("claudespaces-global:")
