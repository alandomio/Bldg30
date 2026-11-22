import json, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import wire


class Live(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "state").mkdir()
        self.old = (wire.FM_HOME, wire.LIVE)
        wire.FM_HOME, wire.LIVE = root, root / "out" / "live.json"

    def tearDown(self):
        wire.FM_HOME, wire.LIVE = self.old
        self.tmp.cleanup()

    def status(self, name, text):
        (wire.FM_HOME / "state" / f"{name}.status").write_text(text)

    def test_parses_state_key_time_and_text(self):
        p = wire.parse_status_line("needs-decision [key=pick-one] [at=1793887000]: which option: A or B?")
        self.assertEqual(p, ("needs-decision", "pick-one", 1793887000, "which option: A or B?"))
        self.assertEqual(wire.parse_status_line("done [corr=ab12] [at=1793887000]: ok")[0:3], ("done", None, 1793887000))
        self.assertIsNone(wire.parse_status_line("working: no time here"))
        self.assertIsNone(wire.parse_status_line("continuation of a long note: not a state line [at=1793887000]"))

    def test_live_json_is_newest_first_capped_and_valid(self):
        self.status("alpha", "working [at=1793880000]: a1\ndone [at=1793890000]: a2\nnoise\n")
        self.status("beta", "blocked [key=k1] [at=1793885000]: b1\n")
        self.status("big", "".join(f"note [at={1700000000 + i}]: n{i}\n" for i in range(300)))
        self.assertEqual(wire.live(), 0)
        doc = json.loads(wire.LIVE.read_text())
        self.assertEqual(doc["schema"], "companion-live.v1")
        self.assertEqual(len(doc["events"]), 200)
        self.assertEqual([e["task"] for e in doc["events"][:3]], ["alpha", "beta", "alpha"])
        self.assertEqual(doc["events"][1]["key"], "k1")
        self.assertNotIn("key", doc["events"][0])
        self.assertTrue(doc["events"][0]["at"].endswith("Z"))
        ats = [e["at"] for e in doc["events"]]
        self.assertEqual(ats, sorted(ats, reverse=True))

    def test_empty_state_writes_empty_list(self):
        self.assertEqual(wire.live(), 0)
        self.assertEqual(json.loads(wire.LIVE.read_text())["events"], [])


if __name__ == "__main__":
    unittest.main()
