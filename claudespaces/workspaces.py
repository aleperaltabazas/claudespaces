import json
import random
from pathlib import Path

STATE_FILE = Path.home() / ".claudespaces" / "workspaces.json"

ADJECTIVES = [
    "bold", "calm", "dark", "deep", "fast", "free", "hard", "high",
    "kind", "last", "late", "long", "loud", "mild", "near", "next",
    "nice", "open", "pure", "rare", "real", "rich", "safe", "slim",
    "slow", "soft", "tall", "thin", "tiny", "vast", "warm", "wide",
    "wild", "wise", "blue", "cold", "cool", "dull", "fair", "firm",
    "flat", "full", "gray", "keen", "lazy", "lean", "live", "lost",
    "mad", "neat",
]

NOUNS = [
    "space", "orbit", "comet", "cloud", "creek", "delta", "drift",
    "dusk", "echo", "field", "flame", "flare", "flash", "flow",
    "forge", "frost", "glade", "gleam", "grove", "haven", "haze",
    "isle", "lake", "leap", "light", "lodge", "loom", "lunar",
    "marsh", "mist", "moon", "moss", "nova", "ocean", "peak",
    "plain", "prism", "pulse", "ridge", "rift", "river", "rock",
    "shade", "shore", "sky", "slope", "snow", "solar", "spark",
    "star", "stone",
]


def _load() -> list[dict]:
    if not STATE_FILE.exists():
        _migrate_from_sessions()
        if not STATE_FILE.exists():
            return []
    with open(STATE_FILE) as f:
        return json.load(f)


def _migrate_from_sessions() -> None:
    old = STATE_FILE.parent / "sessions.json"
    if not old.exists():
        return
    with open(old) as f:
        data = json.load(f)
    for w in data:
        w.pop("id", None)
    _save(data)


def _save(workspace_list: list[dict]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(workspace_list, f, indent=2)


def all_workspaces() -> list[dict]:
    return _load()


def get_workspace_by_name(name: str) -> dict | None:
    for w in _load():
        if w["name"] == name:
            return w
    return None


def name_exists(name: str) -> bool:
    return get_workspace_by_name(name) is not None


def save_workspace(workspace: dict) -> None:
    data = _load()
    data.append(workspace)
    _save(data)


def update_workspace(name: str, **fields) -> None:
    data = _load()
    for w in data:
        if w["name"] == name:
            w.update(fields)
            _save(data)
            return
    raise ValueError(f"Workspace not found: {name}")


def remove_workspace(name: str) -> None:
    _save([w for w in _load() if w["name"] != name])


def heal_running_workspaces(running_container_ids: set[str]) -> None:
    data = _load()
    changed = False
    for w in data:
        if w["status"] == "running" and w["container_id"] not in running_container_ids:
            w["status"] = "stopped"
            changed = True
    if changed:
        _save(data)


def state_dir(name: str) -> Path:
    return Path.home() / ".claudespaces" / name


def generate_name(existing_names: set[str]) -> str:
    for _ in range(10_000):
        name = f"{random.choice(ADJECTIVES)}-{random.choice(NOUNS)}"
        if name not in existing_names:
            return name
    raise RuntimeError("Could not generate a unique name after 10000 attempts")
