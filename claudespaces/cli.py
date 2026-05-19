import os
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import click
import docker
import questionary
import typer

from claudespaces import config, container, image, sessions
from typer.core import TyperGroup


class _PathAwareGroup(TyperGroup):
    """Allow bare directory paths as positional args alongside named subcommands.

    Click normally routes the first positional token as a subcommand name.
    If the token is not a registered command we move it (and all following
    args) back into ``ctx.args`` so the ``invoke_without_command`` callback
    can consume them as directory paths instead.
    """

    def invoke(self, ctx: click.Context) -> object:
        if ctx._protected_args:
            first = ctx._protected_args[0]
            if first not in self.commands:
                ctx.args = ctx._protected_args + ctx.args
                ctx._protected_args = []
        return super().invoke(ctx)


app = typer.Typer(cls=_PathAwareGroup)


def _now_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@app.callback(invoke_without_command=True)
def main(
    ctx: typer.Context,
    image_name: Optional[str] = typer.Option(None, "--image"),
    dockerfile: Optional[str] = typer.Option(None, "--dockerfile"),
) -> None:
    if ctx.invoked_subcommand is not None:
        return

    dirs: list[str] = [*ctx.args] if ctx.args else []

    try:
        cfg = config.load_config()
    except ValueError as e:
        typer.echo(str(e))
        raise typer.Exit(1)

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
            typer.echo("No directories specified. Usage: claudespaces DIR [DIR...]")
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

    credentials_path = Path.home() / ".claude" / ".credentials.json"
    if not credentials_path.exists():
        typer.echo(
            "Warning: ~/.claude/.credentials.json not found. "
            "Claude will prompt you to log in inside the container."
        )

    if dockerfile:
        dockerfile = os.path.abspath(os.path.expanduser(dockerfile))

    try:
        resolved_image = image.resolve_image(image_name, dockerfile, docker_client)
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
    sessions.heal_running_sessions(running_ids)

    existing = sessions.get_sessions_for_dirs(resolved_dirs)

    if not existing:
        action = "new"
        selected = None
    else:
        choices = [questionary.Choice("[ New session ]", value="__new__")]
        for s in existing:
            dt = datetime.fromisoformat(s["last_used_at"].replace("Z", "+00:00"))
            local_time = dt.astimezone().strftime("%Y-%m-%d %H:%M")
            label = f"{s['name']}   {s['status']}   {local_time}"
            is_running = s["status"] == "running"
            choices.append(questionary.Choice(
                label,
                value=s["id"],
                disabled="running" if is_running else False,
            ))

        try:
            selected_id = questionary.select("Select a session:", choices=choices).ask()
        except KeyboardInterrupt:
            raise typer.Exit(0)

        if selected_id is None:
            raise typer.Exit(0)

        if selected_id == "__new__":
            action = "new"
            selected = None
        else:
            action = "resume"
            selected = sessions.get_session_by_id(selected_id)

    claude_dir = str(Path.home() / ".claude")

    if action == "new":
        container_id = container.create_container(
            docker_client, resolved_image, resolved_dirs, claude_dir
        )
        existing_names = {s["name"] for s in sessions.all_sessions()}
        session = {
            "id": secrets.token_hex(4),
            "name": sessions.generate_name(existing_names),
            "dirs": resolved_dirs,
            "container_id": container_id,
            "image": resolved_image,
            "created_at": _now_utc(),
            "last_used_at": _now_utc(),
            "status": "running",
        }
        sessions.save_session(session)
        session_id = session["id"]
        try:
            container.attach_container(container_id)
        finally:
            sessions.update_session(session_id, status="stopped", last_used_at=_now_utc())
    else:
        session_id = selected["id"]
        container_id = selected["container_id"]
        sessions.update_session(session_id, status="running")
        try:
            container.attach_container(container_id)
        finally:
            sessions.update_session(session_id, status="stopped", last_used_at=_now_utc())


@app.command()
def list() -> None:
    all_sess = sessions.all_sessions()
    if not all_sess:
        typer.echo("No sessions found.")
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

    sorted_all = sorted(all_sess, key=lambda s: s["last_used_at"], reverse=True)
    typer.echo(f"{'ID':<10}{'NAME':<14}{'STATUS':<10}{'DIRS':<42}LAST USED")
    typer.echo("-" * 90)
    for s in sorted_all:
        typer.echo(
            f"{s['id']:<10}{s['name']:<14}{s['status']:<10}{fmt_dirs(s['dirs']):<42}{fmt_time(s['last_used_at'])}"
        )


@app.command()
def stop(session_id: str) -> None:
    session = sessions.get_session_by_id(session_id)
    if session is None:
        typer.echo(f"Session not found: {session_id}")
        raise typer.Exit(1)

    if session["status"] == "stopped":
        typer.echo(f"Session {session['name']} ({session_id}) is already stopped.")
        raise typer.Exit(0)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    try:
        container.stop_container(docker_client, session["container_id"])
    except Exception as e:
        typer.echo(f"Failed to stop container: {e}")
        raise typer.Exit(1)
    sessions.update_session(session_id, status="stopped")
    typer.echo(f"Stopped session {session['name']} ({session_id}).")


@app.command()
def remove(session_id: str) -> None:
    session = sessions.get_session_by_id(session_id)
    if session is None:
        typer.echo(f"Session not found: {session_id}")
        raise typer.Exit(1)

    try:
        docker_client = docker.from_env()
    except Exception:
        typer.echo("Docker is not running or not reachable.")
        raise typer.Exit(1)

    try:
        container.remove_container(docker_client, session["container_id"])
    except Exception as e:
        typer.echo(f"Failed to remove container: {e}")
        raise typer.Exit(1)
    sessions.remove_session(session_id)
    typer.echo(f"Removed session {session['name']} ({session_id}).")
