import pytest
from unittest.mock import MagicMock, call
import docker
from claudespaces.image import resolve_image


@pytest.fixture
def client():
    c = MagicMock()
    c.images.build.return_value = (MagicMock(), [])
    return c


def test_default_returns_ubuntu_tag(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image(None, None, client)
    assert result == "claudespaces-base:ubuntu-24.04"


def test_named_image_derives_tag(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image("myrepo/img:tag", None, client)
    assert result == "claudespaces-base:myrepo-img-tag"


def test_named_image_colon_slash_replaced(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    result = resolve_image("registry.io/org/image:v1.2", None, client)
    assert result == "claudespaces-base:registry.io-org-image-v1.2"


def test_missing_dockerfile_raises_file_not_found(client, tmp_path):
    with pytest.raises(FileNotFoundError):
        resolve_image(None, str(tmp_path / "Dockerfile"), client)


def test_cache_hit_skips_build(client):
    client.images.get.return_value = MagicMock()  # image exists
    result = resolve_image(None, None, client)
    assert result == "claudespaces-base:ubuntu-24.04"
    client.images.build.assert_not_called()


def test_cache_miss_triggers_build(client):
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, None, client)
    client.images.build.assert_called_once()
    kwargs = client.images.build.call_args.kwargs
    assert kwargs["tag"] == "claudespaces-base:ubuntu-24.04"


def test_dockerfile_triggers_two_builds(client, tmp_path):
    dockerfile = tmp_path / "Dockerfile"
    dockerfile.write_text("FROM ubuntu:24.04\n")
    client.images.get.side_effect = docker.errors.ImageNotFound("not found")
    resolve_image(None, str(dockerfile), client)
    assert client.images.build.call_count == 2
