#!/usr/bin/env python3
"""Keep board-state.json and board-state.js in step, so a sandboxed Lavish page can read the row updates.

The page cannot fetch board-state.json (no CORS headers), but it can load board-state.js as a script.
Usage: board_state.py DIR                  rewrite board-state.js from DIR/board-state.json (empty rows if absent)
       board_state.py DIR ROW_ID '{json}'  merge the patch into that row, then rewrite both files
"""
import datetime, json, os, sys
from pathlib import Path


def write_atomic(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def record_answer(row_id, decided):
    """An answered decision is also kept in decided.json (key = board task key), so a rebuild never brings it back."""
    home = Path(os.environ.get("LINEAR_ACTION_BOARD_HOME") or "~/.config/linear-action-board").expanduser()
    home.mkdir(parents=True, exist_ok=True)
    f = home / "decided.json"
    try:
        records = json.loads(f.read_text())
    except (OSError, ValueError):
        records = []
    key = "board-" + row_id[len("row-"):] if row_id.startswith("row-") else row_id
    records = [r for r in records if r.get("key") != key] + [
        {"key": key, "option": decided.get("option", ""), "date": datetime.date.today().isoformat()}]
    write_atomic(f, json.dumps(records, indent=1) + "\n")


def sync(folder, row_id=None, patch=None):
    folder = Path(folder)
    src = folder / "board-state.json"
    state = json.loads(src.read_text()) if src.exists() else {}
    state.setdefault("rows", {})
    if row_id:
        old = state["rows"].get(row_id, {})
        merged = {**old, **patch}
        if isinstance(patch.get("drafts"), list):  # a draft patch touches one box: merge by id, keep the others
            by_id = {d["id"]: d for d in old.get("drafts", []) if "id" in d}
            for d in patch["drafts"]:
                by_id[d["id"]] = {**by_id.get(d["id"], {}), **d}
            merged["drafts"] = list(by_id.values())
        state["rows"][row_id] = merged
        if isinstance(patch.get("decided"), dict):
            record_answer(row_id, patch["decided"])
    write_atomic(src, json.dumps(state, indent=1) + "\n")
    write_atomic(folder / "board-state.js", "window.boardState = " + json.dumps(state) + ";\n")
    return state


if __name__ == "__main__":
    if len(sys.argv) not in (2, 4):
        sys.exit(__doc__)
    patch = json.loads(sys.argv[3]) if len(sys.argv) == 4 else None
    sync(sys.argv[1], sys.argv[2] if patch is not None else None, patch)
