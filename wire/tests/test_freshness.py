"""Freshness (test D), producer side: wire/bin/freshness.py wakes once per stale feed, stays silent while fresh, and files
one note in the owner's firstmate home when asked. The app side is Tests/ModelDeckCoreTests/FreshnessTests.swift."""
import io, json, sys, tempfile, unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import freshness
from test_ack_nudge import STUB

NOW = datetime(2026, 11, 19, 12, 0, tzinfo=timezone.utc)


class Freshness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.feed, self.state = self.root / "feed.json", self.root / "state" / "freshness.json"

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, minutes_old):
        at = (NOW - timedelta(minutes=minutes_old)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.feed.write_text(json.dumps({"schema": "companion-feed.v1", "generated_at": at}))
        return at

    def run_check(self, *extra):
        out = io.StringIO()
        with redirect_stdout(out):
            code = freshness.main(["--feed", str(self.feed), "--state", str(self.state), *extra], now=NOW)
        return code, out.getvalue().strip()

    def test_fresh_feed_is_silent(self):
        self.write(29)
        self.assertEqual(self.run_check(), (0, ""))

    def test_feed_older_than_30_minutes_wakes_once(self):
        at = self.write(31)
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn(f"ShipDeck feed is stale: generated {at}, 31 min ago (limit 30)", out)
        self.assertEqual(self.run_check(), (0, ""), "the same stale feed must not wake again")
        self.write(45)  # a newer feed that is stale again (the producer ran once and stopped) wakes again
        self.assertEqual(self.run_check()[0], 1)

    def test_recovery_resets_so_the_next_stall_wakes(self):
        self.write(40)
        self.assertEqual(self.run_check()[0], 1)
        self.write(1)
        self.assertEqual(self.run_check(), (0, ""))
        self.write(40)
        self.assertEqual(self.run_check()[0], 1)

    def test_missing_or_broken_feed_wakes(self):
        code, out = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn("ShipDeck feed unreadable", out)
        self.feed.write_text("{not json")
        self.assertEqual(self.run_check(), (0, ""), "already reported as unreadable")

    def test_owner_home_gets_one_note(self):
        home = self.root / "owner"
        (home / "bin").mkdir(parents=True)
        tool = home / "bin" / "fm-inbox.sh"
        tool.write_text(STUB)
        tool.chmod(0o755)
        self.write(31)
        self.assertEqual(self.run_check("--notify-home", str(home))[0], 1)
        self.run_check("--notify-home", str(home))
        notes = list((home / "state" / "inbox").glob("*.note"))
        self.assertEqual(len(notes), 1)
        self.assertIn("ShipDeck feed is stale", notes[0].read_text())

    def test_a_failed_note_is_retried(self):
        self.write(31)
        code, out = self.run_check("--notify-home", str(self.root / "no-such-home"))
        self.assertEqual(code, 1)
        self.assertIn("Notifying", out)
        self.assertFalse(self.state.exists(), "a failed wake is not recorded, so the next run tries again")


if __name__ == "__main__":
    unittest.main()
