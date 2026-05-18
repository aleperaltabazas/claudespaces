from pathlib import Path
import yaml


def load_config(cwd: str = ".") -> dict:
    path = Path(cwd) / "claudespaces.yml"
    if not path.exists():
        return {}
    with open(path) as f:
        config = yaml.safe_load(f) or {}
    if "image" in config and "dockerfile" in config:
        raise ValueError("claudespaces.yml: 'image' and 'dockerfile' are mutually exclusive")
    return config
