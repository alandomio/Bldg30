"""Load local organisation values. See docs/shipdeck-wire.md for configuration."""
import json, os
from pathlib import Path

CONFIG = Path(os.environ.get("SHIPDECK_ORG_CONFIG") or "~/.config/shipdeck/org.json").expanduser()
DEFAULTS = {
    "gitlab_group": "example-group",
    "linear_workspace": "example",
    "projects": {},
    "ticket_prefixes": [],
    "ships": {"apply": [], "release": []},
    "knowledge_search": "knowledge-base search",
}


def load(path=CONFIG):
    """DEFAULTS with the file's keys on top; a missing file gives DEFAULTS, an unreadable one raises (never guess silently)."""
    cfg = dict(DEFAULTS)
    p = Path(path).expanduser()
    if p.is_file():
        data = json.loads(p.read_text())
        if not isinstance(data, dict):
            raise ValueError(f"{p}: org config must be a JSON object")
        cfg.update({k: v for k, v in data.items() if not k.startswith("_")})
    return cfg


ORG = load()
GITLAB_GROUP = ORG["gitlab_group"].strip("/")
GITLAB_BASE = f"https://gitlab.com/{GITLAB_GROUP}/"
LINEAR_ISSUE_BASE = f"https://linear.app/{ORG['linear_workspace']}/issue/"
PROJECTS = dict(ORG["projects"])
TICKET_PREFIXES = list(ORG["ticket_prefixes"])
SHIPS = {"apply": list(ORG["ships"].get("apply", [])), "release": list(ORG["ships"].get("release", []))}
# Named in the "Add context" prompt: "run a <knowledge_search> and attach the matching cards".
KNOWLEDGE_SEARCH = str(ORG["knowledge_search"])
