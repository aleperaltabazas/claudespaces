# Additional mounts

Allow users to add custom files/dirs to mount into the container via `claudespaces.yml` (project-level) and `~/.claudespaces/config.yml` (global).

## Config format

Compose-style strings under an `additional-mounts` key:

```yaml
additional-mounts:
  - /home/user/documentation:/home/container/documentation:ro
  - /home/user/scripts:/scripts:rw
```

Format: `src:dst` or `src:dst:ro|rw`. Mode defaults to `rw` when omitted.

## Merge behaviour

Global and project mounts are merged. If both define a mount with the same container target path, raise a `ValueError` before any container is created (same pattern as basename collision for workspace dirs).

## Implementation notes

- Parse in `config.py` alongside existing keys.
- Pass resolved mount list into `create_container` and append to the `mounts` list before `docker_client.containers.create`.
- No entrypoint involvement needed — these are plain bind mounts.
