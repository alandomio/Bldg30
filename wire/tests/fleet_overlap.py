"""Emit real producer output for the Swift Fleet identity regression. No home or service access."""
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import workers


def snapshot():
    summary = {
        "generated_epoch": 1794585000,
        "active_children": [{"id": "held-worker", "kind": "scout", "state": "parked"}],
        "endpoints": [{"id": "held-worker", "state": "parked"}],
        "decisions_open": [{"id": "held-worker", "summary": "Pick a scope", "hold_age_days": 2}],
    }

    def fake_run(command, **kwargs):
        assert command == ["/fixture/firstmate/bin/fm-on.sh", "remote", "fm-remote-file.sh",
                           "get", "state/home-summary.json", "1048576"]
        return SimpleNamespace(stdout=json.dumps(summary), returncode=0)

    with patch.object(workers, "MAIN", Path("/fixture/firstmate")):
        home = workers.collect_remote("remote", "/fixture/remote", "agent-host", 1794585600, fake_run)
    assert [(row["id"], row["kind"]) for row in home["workers"]] == [
        ("held-worker", "scout"), ("held-worker", "decision")]
    return {"schema": "companion-workers.v1", "generated_at": workers.iso(1794585600), "homes": [home]}


if __name__ == "__main__":
    print(json.dumps(snapshot()))
