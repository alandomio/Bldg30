import sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import wire


def click(action, target="worker:w1", text=None):
    c = {"action_id": action, "target": target, "created_at": "t", "idempotency_key": "k" * 8}
    if text:
        c["draft_text"] = text
    return c


class WorkerClicks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        (Path(self.tmp.name) / "state").mkdir()
        (Path(self.tmp.name) / "state" / "w1.meta").write_text("kind=scout\n")
        self.old = wire.FM_HOME
        wire.FM_HOME = Path(self.tmp.name)

    def tearDown(self):
        wire.FM_HOME = self.old
        self.tmp.cleanup()

    def test_known_worker_actions_are_not_stale(self):
        for a in ["worker.sweep", "worker.cleanup", "worker.discard", "worker.steer", "worker.merge", "worker.spawn"]:
            body = wire.click_body(click(a), {})
            self.assertNotIn("treat as stale", body, a)
            self.assertIn("Worker click for task w1", body, a)

    def test_sweep_checks_drafts_and_carries_the_text(self):
        body = wire.click_body(click("worker.sweep", text="Not safe to approve."), {})
        self.assertIn("unposted review drafts", body)
        self.assertIn("Not safe to approve.", body)

    def test_unknown_worker_is_named_not_stale(self):
        body = wire.click_body(click("worker.sweep", target="worker:gone"), {})
        self.assertIn("not a worker of this home", body)
        self.assertNotIn("treat as stale", body)

    def test_other_unknown_action_stays_stale(self):
        self.assertIn("treat as stale", wire.click_body(click("nope.x"), {}))


if __name__ == "__main__":
    unittest.main()
