# Session memory

Give each workspace its own isolated Claude session history instead of sharing a global `~/.claude/sessions`.

## Storage

Per-workspace sessions live on the host at `~/.claudespaces/<name>/session/`. This directory is created alongside the other per-workspace state dirs (`claude.json`, `projects/`) when the workspace is first created.

## Mount strategy

Same approach as `settings.json` / `.credentials.json`: mount the host dir to a staging path (e.g. `/claudespaces/host/session`) read-write, then let `entrypoint.sh` symlink or copy it into place at `~/.claude/sessions` before Claude starts. This avoids the container's Claude install overwriting a direct mount.

## Scope

- Clean slate: existing workspaces do not need migration.
- No CLI commands for browsing or exporting sessions — isolation only. Users can manually access `~/.claudespaces/<name>/session/` on the host if needed.
