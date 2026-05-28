import json
from pathlib import Path

import yaml

from claudespaces.config import GLOBAL_CONFIG_PATH

DEFAULT_PORT = 7731
SHIMS_PATH = Path.home() / ".claudespaces" / "shims.json"

_BUILTIN_OPERATIONS: dict = {
    "notify": {
        "command": "notify-send {summary} {body}",
        "args": ["summary", "body"],
        "async": True,
        "override": "notify-send",
    }
}


def load_host_bridge() -> dict:
    """Return {"port": int, "operations": dict} merged from builtins and user config."""
    if GLOBAL_CONFIG_PATH.exists():
        with open(GLOBAL_CONFIG_PATH) as f:
            global_cfg = yaml.safe_load(f) or {}
    else:
        global_cfg = {}

    bridge_cfg = global_cfg.get("host_bridge", {})
    port = bridge_cfg.get("port", DEFAULT_PORT)

    operations = dict(_BUILTIN_OPERATIONS)
    operations.update(bridge_cfg.get("operations", {}))

    return {"port": port, "operations": operations}


def overrides_manifest(operations: dict) -> dict:
    """Return {binary_name: op_name} for operations that declare an override."""
    return {
        op["override"]: name
        for name, op in operations.items()
        if "override" in op
    }


def write_shims(operations: dict) -> None:
    """Write the shims manifest to SHIMS_PATH for bind-mounting into containers."""
    SHIMS_PATH.parent.mkdir(parents=True, exist_ok=True)
    manifest = overrides_manifest(operations)
    SHIMS_PATH.write_text(json.dumps(manifest, indent=2))
