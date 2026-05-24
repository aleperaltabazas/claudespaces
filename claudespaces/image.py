import hashlib
import os
import re
import sys
from pathlib import Path

import docker


def resolve_image(
    image: str | None,
    global_dockerfile: str | None,
    dockerfile: str | None,
    docker_client,
) -> str:
    base_tag = _build_pre_claude_base(image, global_dockerfile, dockerfile, docker_client)

    base_dockerfile = Path(__file__).parent / "Dockerfile.base"
    dockerfile_hash = hashlib.md5(base_dockerfile.read_bytes()).hexdigest()[:12]
    intermediate_tag = "claudespaces-base:" + re.sub(r"[:/]", "-", base_tag) + "-" + dockerfile_hash

    try:
        docker_client.images.get(intermediate_tag)
        return intermediate_tag
    except docker.errors.ImageNotFound:
        pass

    print(f"Building {intermediate_tag} ...")
    _build(
        docker_client,
        path=str(base_dockerfile.parent),
        dockerfile=base_dockerfile.name,
        tag=intermediate_tag,
        buildargs={"BASE_IMAGE": base_tag},
    )

    return intermediate_tag


def _build_pre_claude_base(
    image: str | None,
    global_dockerfile: str | None,
    dockerfile: str | None,
    docker_client,
) -> str:
    if global_dockerfile is not None and not os.path.exists(global_dockerfile):
        raise FileNotFoundError(f"Global Dockerfile not found: {global_dockerfile}")
    if dockerfile is not None and not os.path.exists(dockerfile):
        raise FileNotFoundError(f"Dockerfile not found: {dockerfile}")

    current = image or "ubuntu:24.04"

    if global_dockerfile is not None:
        abs_path = os.path.abspath(global_dockerfile)
        slug = hashlib.md5(f"{abs_path}:{current}".encode()).hexdigest()[:12]
        tag = f"claudespaces-global:{slug}"
        try:
            docker_client.images.get(tag)
        except docker.errors.ImageNotFound:
            print(f"Building {tag} ...")
            _build(
                docker_client,
                path=os.path.dirname(abs_path),
                dockerfile=os.path.basename(abs_path),
                tag=tag,
                buildargs={"BASE_IMAGE": current},
            )
        current = tag

    if dockerfile is not None:
        abs_path = os.path.abspath(dockerfile)
        slug = hashlib.md5(f"{abs_path}:{current}".encode()).hexdigest()[:12]
        tag = f"claudespaces-custom:{slug}"
        print(f"Building {tag} ...")
        _build(
            docker_client,
            path=os.path.dirname(abs_path),
            dockerfile=os.path.basename(abs_path),
            tag=tag,
            buildargs={"BASE_IMAGE": current},
        )
        current = tag

    return current


def _build(docker_client, **kwargs) -> None:
    stream = docker_client.api.build(decode=True, rm=True, **kwargs)
    for chunk in stream:
        if "stream" in chunk:
            sys.stdout.write(chunk["stream"])
            sys.stdout.flush()
        elif "error" in chunk:
            raise docker.errors.BuildError(chunk["error"], iter([chunk]))
