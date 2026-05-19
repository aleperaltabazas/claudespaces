import json
import random
from pathlib import Path

STATE_FILE = Path.home() / ".claudespaces" / "sessions.json"

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
        return []
    with open(STATE_FILE) as f:
        return json.load(f)


def _save(session_list: list[dict]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(session_list, f, indent=2)


def all_sessions() -> list[dict]:
    return _load()


def get_sessions_for_dirs(dirs: list[str]) -> list[dict]:
    key = sorted(dirs)
    return [s for s in _load() if s["dirs"] == key]


def get_session_by_id(session_id: str) -> dict | None:
    for s in _load():
        if s["id"] == session_id:
            return s
    return None


def save_session(session: dict) -> None:
    data = _load()
    data.append(session)
    _save(data)


def update_session(session_id: str, **fields) -> None:
    data = _load()
    for s in data:
        if s["id"] == session_id:
            s.update(fields)
    _save(data)


def remove_session(session_id: str) -> None:
    _save([s for s in _load() if s["id"] != session_id])


def heal_running_sessions(running_container_ids: set[str]) -> None:
    data = _load()
    changed = False
    for s in data:
        if s["status"] == "running" and s["container_id"] not in running_container_ids:
            s["status"] = "stopped"
            changed = True
    if changed:
        _save(data)


def generate_name(existing_names: set[str]) -> str:
    for _ in range(10_000):
        name = f"{random.choice(ADJECTIVES)}-{random.choice(NOUNS)}"
        if name not in existing_names:
            return name
    raise RuntimeError("Could not generate a unique name after 10000 attempts")
