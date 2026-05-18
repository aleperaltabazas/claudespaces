import os
import subprocess

import docker
from docker.types import Mount

CLAUDE_CONFIG_PATHS = [
    (".credentials.json", "/root/.claude/.credentials.json"),
    ("settings.json", "/root/.claude/settings.json"),
    ("CLAUDE.md", "/root/.claude/CLAUDE.md"),
    ("plugins", "/root/.claude/plugins"),
    ("skills", "/root/.claude/skills"),
]


def get_running_container_ids(docker_client) -> set[str]:
    containers = docker_client.containers.list(filters={"status": "running"})
    return {c.id for c in containers}


def create_container(docker_client, image: str, dirs: list[str], claude_dir: str) -> str:
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

    for rel_path, container_path in CLAUDE_CONFIG_PATHS:
        host_path = os.path.join(claude_dir, rel_path)
        if os.path.exists(host_path):
            mounts.append(Mount(
                target=container_path,
                source=host_path,
                type="bind",
                read_only=True,
            ))

    container = docker_client.containers.create(
        image=image,
        command=["claude"],
        tty=True,
        stdin_open=True,
        working_dir="/workspace",
        mounts=mounts,
    )
    return container.id


def attach_container(container_id: str) -> int:
    result = subprocess.run(["docker", "start", "-ai", container_id])
    return result.returncode


def stop_container(docker_client, container_id: str) -> None:
    docker_client.containers.get(container_id).stop()


def remove_container(docker_client, container_id: str) -> None:
    try:
        docker_client.containers.get(container_id).remove(force=True)
    except docker.errors.NotFound:
        pass
