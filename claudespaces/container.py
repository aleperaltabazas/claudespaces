import os
import subprocess
from pathlib import Path

import docker
from docker.types import Mount

CONTAINER_USER = "root"


def get_running_container_ids(docker_client) -> set[str]:
    containers = docker_client.containers.list(filters={"status": "running"})
    return {c.id for c in containers}


def create_container(docker_client, image: str, dirs: list[str], state_dir: Path) -> str:
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

    # Per-workspace state mounts (always added; cli.py ensures these exist)
    mounts.append(Mount(
        target="/root/.claude.json",
        source=str(state_dir / "claude.json"),
        type="bind",
        read_only=False,
    ))
    mounts.append(Mount(
        target="/root/.claude/projects",
        source=str(state_dir / "projects"),
        type="bind",
        read_only=False,
    ))

    # Bind-mount the entrypoint from the installed package so it's always current,
    # regardless of which image version is cached.
    entrypoint_src = Path(__file__).parent / "support" / "bin" / "entrypoint.sh"
    if entrypoint_src.exists():
        mounts.append(Mount(
            target="/claudespaces/entrypoint.sh",
            source=str(entrypoint_src),
            type="bind",
            read_only=True,
        ))

    # Selective host config mounts (conditional on existence)
    home = Path.home()
    host_mounts = [
        (home / ".claude" / "settings.json", "/claudespaces/host/settings.json"),
        (home / ".claude" / "plugins", "/claudespaces/host/plugins"),
        (home / ".claude" / ".credentials.json", "/claudespaces/host/credentials.json"),
    ]
    for source, target in host_mounts:
        if source.exists():
            mounts.append(Mount(
                target=target,
                source=str(source),
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
        environment={"IS_SANDBOX": "1", "HOST_HOME": str(Path.home())},
    )
    return container.id


def attach_container(container_id: str) -> None:
    # Start the container (runs entrypoint: config setup + sleep infinity).
    # Then exec with -it so Docker puts the host terminal into raw mode —
    # docker start -ai skips that step, breaking Enter in TUI applications.
    subprocess.run(["docker", "start", container_id], check=True, capture_output=True)
    cmd = ["docker", "exec", "-it"]
    for var in ("TERM", "COLORTERM", "PS1"):
        val = os.environ.get(var)
        if val:
            cmd += ["-e", f"{var}={val}"]
    cmd += [container_id, "/claudespaces/entrypoint.sh"]
    subprocess.run(cmd)


def stop_container(docker_client, container_id: str) -> None:
    docker_client.containers.get(container_id).stop()


def remove_container(docker_client, container_id: str) -> None:
    try:
        docker_client.containers.get(container_id).remove(force=True)
    except docker.errors.NotFound:
        pass
