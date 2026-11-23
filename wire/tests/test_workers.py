import json, subprocess, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import workers


def fake_run(crew_line, panes=None, summary=None):
    def run(cmd, **kw):
        if cmd[0] == "herdr":
            return SimpleNamespace(stdout=json.dumps({"result": {"panes": panes or []}}), returncode=0)
        if cmd[0].endswith("fm-crew-state.sh"):
            return SimpleNamespace(stdout=crew_line + "\n", returncode=0)
        if cmd[0].endswith("fm-on.sh"):
            if summary is None:
                raise subprocess.TimeoutExpired(cmd, 1)
            return SimpleNamespace(stdout=json.dumps(summary), returncode=0)
        raise AssertionError(cmd)
    return run


class LocalWorkers(unittest.TestCase):
    def home(self, meta, status=""):
        d = Path(tempfile.mkdtemp())
        (d / "state").mkdir()
        (d / "state" / "w1.meta").write_text(meta)
        (d / "state" / "w1.status").write_text(status)
        return str(d)

    def test_crew_state_wins_over_an_old_decision_line(self):
        h = self.home("kind=ship\nharness=claude\nmodel=opus\nproject=/x/infra-platform\nwindow=default:w1:p2\n",
                      "needs-decision [at=100]: pick A or B\n")
        w = workers.local_worker(h, "w1", {"w1:p2": "idle"}, 1000, fake_run("state: working · source: pane · harness busy"))
        self.assertEqual((w["state"], w["project"], w["model"]), ("working", "infra-platform", "opus"))

    def test_parked_is_waiting_on_a_decision_with_its_text(self):
        h = self.home("kind=scout\nwindow=default:w1:p2\n", "needs-decision [at=100]: pick A or B https://gitlab.com/x/-/merge_requests/9\n")
        w = workers.local_worker(h, "w1", {"w1:p2": "idle"}, 1000, fake_run("state: parked · source: status-log · pick A or B"))
        self.assertEqual(w["state"], "waiting on a decision")
        self.assertEqual(w["age_seconds"], 900)
        self.assertIn("https://gitlab.com/x/-/merge_requests/9", w["links"])
        self.assertTrue(w["waiting_on"].startswith("pick A or B"))

    def test_unknown_state_uses_the_pane(self):
        h = self.home("kind=ship\nwindow=default:w1:p2\n")
        unk = "state: unknown · source: pane · harness state unavailable"
        self.assertEqual(workers.local_worker(h, "w1", {"w9:p1": "idle"}, 1000, fake_run(unk))["state"], "dead")
        self.assertEqual(workers.local_worker(h, "w1", {"w1:p2": "exited"}, 1000, fake_run(unk))["state"], "stopped")
        self.assertEqual(workers.local_worker(h, "w1", {"w1:p2": "blocked"}, 1000, fake_run(unk))["state"], "waiting on a prompt")

    def test_second_mates_are_homes_not_workers(self):
        h = self.home("kind=secondmate\nwindow=remote:alwayson\n")
        self.assertIsNone(workers.local_worker(h, "w1", {}, 1000, fake_run("state: working")))


class RemoteWorkers(unittest.TestCase):
    def test_summary_rows_and_open_decisions(self):
        s = {"generated_epoch": 900, "active_children": [{"id": "rv-1", "kind": "scout", "state": "working", "repo": "infra-platform", "doing": "busy"}],
             "endpoints": [{"id": "rv-1", "state": "working"}, {"id": "old", "state": "unknown", "endpoint": {"status": "absent"}}],
             "decisions_open": [{"id": "d1", "summary": "Pick a scope", "reason": "two options", "hold_age_days": 2}], "omitted": []}
        h = workers.collect_remote("alwayson", "/mnt/h", "agent-host", 1000, fake_run("", summary=s))
        self.assertTrue(h["ok"])
        self.assertEqual([(w["id"], w["state"]) for w in h["workers"]], [("rv-1", "working"), ("old", "dead"), ("d1", "waiting on a decision")])
        self.assertEqual(h["workers"][0]["age_seconds"], 100)

    def test_unreachable_host_is_an_error_not_an_empty_fleet(self):
        h = workers.collect_remote("alwayson", "/mnt/h", "agent-host", 1000, fake_run("", summary=None))
        self.assertFalse(h["ok"])
        self.assertIn("not readable", h["error"])


if __name__ == "__main__":
    unittest.main()
