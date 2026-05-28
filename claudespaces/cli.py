import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import docker
import typer

from claudespaces import config, container, image, workspaces

app = typer.Typer()


def _now_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@app.command()
def new(
    dirs: list[str] = typer.Argument(...),
    named: Optional[str] = typer.Option(None, "--named"),
    start: bool = typer.Option(False, "--start"),
    image_name: Optional[str] = typer.Option(None, "--image"),
    dockerfile: Optional[str] = typer.Option(None, "--dockerfile"),
) -> None:
    try:
        cfg = config.load_config()
    except ValueError as e:
        typer.echo(str(e))
        raise typer.Exit(1)

    if named is not None and workspaces.name_exists(named):
        typer.echo(f"Workspace '{named}' already exists.")
        raise typer.Exit(1)

    global_dockerfile = cfg.get("global_dockerfile")

    if image_name is None and dockerfile is None:
        image_name = cfg.get("image")
        dockerfile = cfg.get("dockerfile")

    cfg_dirs = [os.path.expanduser(d) for d in cfg.get("directories", [])]
    cli_dirs = [os.path.expanduser(d) for d in (dirs or [])]
    all_dirs = sorted(set(cfg_dirs + cli_dirs))

    if not all_dirs:
        if Path("claudespaces.yml").exists():
            all_dirs = [str(Path.cwd())]
        else:
            typer.echo("No directories specified. Usage: claudespaces new DIR [DIR...]")
            raise typer.Exit(1)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    resolved_dirs = []
    for d in all_dirs:
        abs_d = os.path.abspath(d)
        if not os.path.exists(abs_d):
            typer.echo(f"Directory not found: {abs_d}")
            raise typer.Exit(1)
        if not os.path.isdir(abs_d):
            typer.echo(f"Not a directory: {abs_d}")
            raise typer.Exit(1)
        resolved_dirs.append(abs_d)

    if global_dockerfile:
        global_dockerfile = os.path.abspath(os.path.expanduser(global_dockerfile))
    if dockerfile:
        dockerfile = os.path.abspath(os.path.expanduser(dockerfile))

    try:
        resolved_image = image.resolve_image(image_name, global_dockerfile, dockerfile, docker_client)
    except FileNotFoundError as e:
        typer.echo(str(e))
        raise typer.Exit(1)
    except docker.errors.BuildError as e:
        typer.echo(f"Docker build failed: {e}")
        for entry in e.build_log:
            if isinstance(entry, dict) and "stream" in entry:
                typer.echo(entry["stream"], nl=False)
        raise typer.Exit(1)

    running_ids = container.get_running_container_ids(docker_client)
    workspaces.heal_running_workspaces(running_ids)

    existing_names = {w["name"] for w in workspaces.all_workspaces()}
    name = named if named is not None else workspaces.generate_name(existing_names)

    sd = workspaces.state_dir(name)
    sd.mkdir(parents=True, exist_ok=True)
    (sd / "projects").mkdir(exist_ok=True)
    claude_json = sd / "claude.json"
    if not claude_json.exists():
        host_claude_json = Path.home() / ".claude.json"
        claude_json.write_text(
            host_claude_json.read_text() if host_claude_json.exists() else "{}"
        )

    try:
        container_id = container.create_container(docker_client, resolved_image, resolved_dirs, state_dir=sd)
    except ValueError as e:
        typer.echo(str(e))
        raise typer.Exit(1)

    workspace = {
        "name": name,
        "dirs": resolved_dirs,
        "container_id": container_id,
        "image": resolved_image,
        "created_at": _now_utc(),
        "last_used_at": _now_utc(),
        "status": "stopped",
    }
    workspaces.save_workspace(workspace)
    typer.echo(f"Created workspace '{name}'.")

    if start:
        workspaces.update_workspace(name, status="running")
        try:
            container.attach_container(container_id)
        except KeyboardInterrupt:
            pass
        finally:
            workspaces.update_workspace(name, status="stopped", last_used_at=_now_utc())
            container.stop_container(docker_client, container_id)


@app.command()
def start(name: str) -> None:
    workspace = workspaces.get_workspace_by_name(name)
    if workspace is None:
        typer.echo(f"Workspace '{name}' not found.")
        raise typer.Exit(1)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    running_ids = container.get_running_container_ids(docker_client)
    workspaces.heal_running_workspaces(running_ids)

    workspace = workspaces.get_workspace_by_name(name)
    if workspace["status"] == "running":
        typer.echo(f"Workspace '{name}' is already running.")
        raise typer.Exit(1)

    sd = workspaces.state_dir(name)
    if not sd.exists():
        typer.echo(f"Migrating workspace '{name}' to new mount layout...")
        sd.mkdir(parents=True, exist_ok=True)
        (sd / "projects").mkdir(exist_ok=True)
        claude_json = sd / "claude.json"
        host_claude_json = Path.home() / ".claude.json"
        claude_json.write_text(
            host_claude_json.read_text() if host_claude_json.exists() else "{}"
        )
        container.remove_container(docker_client, workspace["container_id"])
        new_id = container.create_container(
            docker_client, workspace["image"], workspace["dirs"], state_dir=sd
        )
        workspaces.update_workspace(name, container_id=new_id)
        workspace = workspaces.get_workspace_by_name(name)

    workspaces.update_workspace(name, status="running")
    try:
        container.attach_container(workspace["container_id"])
    except KeyboardInterrupt:
        pass
    finally:
        workspaces.update_workspace(name, status="stopped", last_used_at=_now_utc())
        container.stop_container(docker_client, workspace["container_id"])


@app.command()
def stop(name: str) -> None:
    workspace = workspaces.get_workspace_by_name(name)
    if workspace is None:
        typer.echo(f"Workspace '{name}' not found.")
        raise typer.Exit(1)

    if workspace["status"] == "stopped":
        typer.echo(f"Workspace '{name}' is already stopped.")
        raise typer.Exit(0)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    try:
        container.stop_container(docker_client, workspace["container_id"])
    except Exception as e:
        typer.echo(f"Failed to stop container: {e}")
        raise typer.Exit(1)
    workspaces.update_workspace(name, status="stopped")
    typer.echo(f"Stopped workspace '{name}'.")


@app.command()
def remove(name: str) -> None:
    workspace = workspaces.get_workspace_by_name(name)
    if workspace is None:
        typer.echo(f"Workspace '{name}' not found.")
        raise typer.Exit(1)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    try:
        container.remove_container(docker_client, workspace["container_id"])
    except Exception as e:
        typer.echo(f"Failed to remove container: {e}")
        raise typer.Exit(1)
    workspaces.remove_workspace(name)
    sd = workspaces.state_dir(name)
    if sd.exists():
        shutil.rmtree(sd)
    typer.echo(f"Removed workspace '{name}'.")


@app.command()
def list() -> None:
    all_ws = workspaces.all_workspaces()
    if not all_ws:
        typer.echo("No workspaces found.")
        raise typer.Exit(0)

    home = str(Path.home())

    def collapse(path: str) -> str:
        return "~" + path[len(home):] if path.startswith(home) else path

    def fmt_dirs(dirs_list: list) -> str:
        joined = ", ".join(collapse(d) for d in dirs_list)
        return joined[:39] + "…" if len(joined) > 40 else joined

    def fmt_time(ts: str) -> str:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%Y-%m-%d %H:%M")

    sorted_all = sorted(all_ws, key=lambda w: w["last_used_at"], reverse=True)
    typer.echo(f"{'NAME':<20}{'STATUS':<10}{'DIRS':<42}LAST USED")
    typer.echo("-" * 85)
    for w in sorted_all:
        typer.echo(
            f"{w['name']:<20}{w['status']:<10}{fmt_dirs(w['dirs']):<42}{fmt_time(w['last_used_at'])}"
        )
