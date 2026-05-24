import os
from pathlib import Path

import docker
from docker.types import Mount

CONTAINER_USER = "root"


def get_running_container_ids(docker_client) -> set[str]:
    containers = docker_client.containers.list(filters={"status": "running"})
    return {c.id for c in containers}


def create_container(docker_client, image: str, dirs: list[str]) -> str:
    basenames = [os.path.basename(d) for d in dirs]
    if len(basenames) != len(set(basenames)):
        dup = next(b for b in basenames if basenames.count(b) > 1)
        raise ValueError(f"Directories share the same basename: {dup!r}")

    mounts = []

    for d in dirs:
        mounts.append(Mount(
            target=f"/workspace/{os.path.basename(d)}",
            source=d,
            type="bind",
            read_only=False,
        ))

    home = Path.home()
    claude_dir = home / ".claude"
    claude_json = home / ".claude.json"

    if claude_dir.exists():
        mounts.append(Mount(
            target="/claudespaces/.claude",
            source=str(claude_dir),
            type="bind",
            read_only=True,
        ))
    if claude_json.exists():
        mounts.append(Mount(
            target="/claudespaces/.claude.json",
            source=str(claude_json),
            type="bind",
            read_only=True,
        ))

    container = docker_client.containers.create(
        image=image,
        tty=True,
        stdin_open=True,
        user=CONTAINER_USER,
        working_dir="/workspace",
        mounts=mounts,
    )
    return container.id


def attach_container(container_id: str) -> None:
    os.execvp("docker", ["docker", "start", "-ai", container_id])


def stop_container(docker_client, container_id: str) -> None:
    docker_client.containers.get(container_id).stop()


def remove_container(docker_client, container_id: str) -> None:
    try:
        docker_client.containers.get(container_id).remove(force=True)
    except docker.errors.NotFound:
        pass
