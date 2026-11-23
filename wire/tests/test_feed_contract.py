"""Feed contract (test A): the producer's output validates against wire/schema/companion-feed.v1, and the sample feeds in
wire/fixtures/feeds are the same files the Swift tests decode (Tests/ModelDeckCoreTests/FeedContractTests.swift).

producer.feed.json is the real producer's output for the synthetic producer-board.json. When a producer change is meant to
change it, regenerate it with WIRE_UPDATE_FIXTURES=1 and commit the new file, so the app is tested against the new shape.
"""
import json, os, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import feed, render

WIRE = Path(__file__).resolve().parent.parent
FEEDS = WIRE / "fixtures" / "feeds"
BOARD = FEEDS / "producer-board.json"
GOLDEN = FEEDS / "producer.feed.json"
GOLDEN_ACTIONS = FEEDS / "producer.feed.actions.json"
DOCS_FIXTURE = WIRE.parent / "docs" / "companion" / "fixture-feed.json"
SCHEMA = feed.load_schema("companion-feed.v1")


def produce():
    """(feed, sidecar actions) from the real producer for the synthetic board, with no access to the user's board home."""
    with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"LINEAR_ACTION_BOARD_HOME": home}), \
            mock.patch("builtins.print"):
        out = Path(home) / "feed.json"
        render.main(str(BOARD), feed_out=str(out))
        return json.loads(out.read_text()), json.loads(out.with_name("feed.actions.json").read_text())["actions"]


class FeedContract(unittest.TestCase):
    def test_producer_output_validates_and_matches_the_committed_sample(self):
        doc, side = produce()
        self.assertEqual(feed.validate(doc, SCHEMA), [])
        if os.environ.get("WIRE_UPDATE_FIXTURES") == "1":
            doc["generated_at"] = "2026-11-19T12:00:00Z"
            GOLDEN.write_text(json.dumps(doc, indent=1) + "\n")
            GOLDEN_ACTIONS.write_text(json.dumps({"schema": "companion-actions.v1", "generated_at": doc["generated_at"], "actions": side}, indent=1) + "\n")
        golden = json.loads(GOLDEN.read_text())
        doc["generated_at"] = golden["generated_at"]
        hint = "producer output changed: if intended, rerun with WIRE_UPDATE_FIXTURES=1 and commit producer.feed.json and producer.feed.actions.json"
        self.assertEqual(doc, golden, hint)
        self.assertEqual(side, json.loads(GOLDEN_ACTIONS.read_text())["actions"], hint)

    def test_producer_keeps_unknown_pipeline_and_threads_as_null(self):
        doc, _ = produce()
        mr = next(m for m in doc["mrs"] if m["ref"] == "pi !1")
        self.assertIsNone(mr["pipeline"])
        self.assertIsNone(mr["open_threads"])

    def test_every_action_and_option_has_a_click_mapping(self):
        """The click pipe maps a click by its action id through feed.actions.json; an id without an entry is a dead button."""
        doc, side = produce()
        ids = [a["id"] for row in doc["mrs"] + doc["tickets"] for a in row["actions"]]
        ids += [o["action_id"] for d in doc["decisions"] for o in d["options"] if o.get("action_id")]
        self.assertTrue(ids)
        self.assertEqual([i for i in ids if i not in side], [])
        self.assertEqual(len(ids), len(set(ids)), "action ids must be unique across the feed")

    def test_every_sample_feed_validates(self):
        samples = sorted(FEEDS.glob("*.feed.json"))
        self.assertGreaterEqual(len(samples), 2)
        for path in samples + [DOCS_FIXTURE]:
            with self.subTest(sample=path.name):
                self.assertEqual(feed.validate(json.loads(path.read_text()), SCHEMA), [])

    def test_invalid_samples_are_rejected(self):
        # invalid/: the whole feed is wrong; invalid-rows/: one row is wrong (the app skips that row, see FeedContractTests).
        samples = sorted((FEEDS / "invalid").glob("*.feed.json")) + sorted((FEEDS / "invalid-rows").glob("*.feed.json"))
        self.assertGreaterEqual(len(samples), 4)
        for path in samples:
            with self.subTest(sample=path.name):
                self.assertNotEqual(feed.validate(json.loads(path.read_text()), SCHEMA), [])


if __name__ == "__main__":
    unittest.main()
