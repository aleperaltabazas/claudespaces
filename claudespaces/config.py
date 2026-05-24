from pathlib import Path
import yaml

GLOBAL_CONFIG_PATH = Path.home() / ".config" / "claudespaces" / "claudespaces.yaml"


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

    return result
