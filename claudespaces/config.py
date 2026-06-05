from pathlib import Path
import yaml

GLOBAL_CONFIG_PATH = Path.home() / ".config" / "claudespaces" / "claudespaces.yaml"


def _parse_mount(entry: str) -> dict:
    parts = entry.split(":")
    if len(parts) < 2 or len(parts) > 3:
        raise ValueError(f"invalid mount entry: {entry!r} (expected src:dst or src:dst:ro|rw)")
    source, target = parts[0], parts[1]
    mode = parts[2] if len(parts) == 3 else "rw"
    if mode not in ("ro", "rw"):
        raise ValueError(f"invalid mount mode {mode!r} in {entry!r} (expected ro or rw)")
    return {"source": source, "target": target, "read_only": mode == "ro"}


def _load_yaml(path: Path) -> dict:
    if not path.exists():
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}


def load_config(cwd: str = ".") -> dict:
    global_cfg = _load_yaml(GLOBAL_CONFIG_PATH)
    if "image" in global_cfg and "dockerfile" in global_cfg:
        raise ValueError(f"{GLOBAL_CONFIG_PATH}: 'image' and 'dockerfile' are mutually exclusive")

    local_cfg = _load_yaml(Path(cwd) / "claudespaces.yml")
    if "image" in local_cfg and "dockerfile" in local_cfg:
        raise ValueError("claudespaces.yml: 'image' and 'dockerfile' are mutually exclusive")

    result = {}

    dirs = list(dict.fromkeys(global_cfg.get("directories", []) + local_cfg.get("directories", [])))
    if dirs:
        result["directories"] = dirs

    if "image" in local_cfg:
        result["image"] = local_cfg["image"]
    elif "image" in global_cfg:
        result["image"] = global_cfg["image"]

    if "dockerfile" in global_cfg:
        result["global_dockerfile"] = global_cfg["dockerfile"]

    if "dockerfile" in local_cfg:
        result["dockerfile"] = local_cfg["dockerfile"]

    global_mounts = [_parse_mount(e) for e in global_cfg.get("additional-mounts", [])]
    local_mounts = [_parse_mount(e) for e in local_cfg.get("additional-mounts", [])]

    global_targets = {m["target"] for m in global_mounts}
    local_targets = {m["target"] for m in local_mounts}
    overlap = global_targets & local_targets
    if overlap:
        raise ValueError(f"additional-mounts: duplicate container target(s): {', '.join(sorted(overlap))}")

    combined = global_mounts + local_mounts
    if combined:
        result["additional_mounts"] = combined

    return result
