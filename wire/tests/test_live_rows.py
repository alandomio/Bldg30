import os, sys, tempfile, unittest
from pathlib import Path
os.environ.setdefault("SHIPDECK_COMPANION", tempfile.mkdtemp())
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import wire

U = "https://gitlab.com/p/x/-/merge_requests/"


class LiveRows(unittest.TestCase):
    def test_rows_come_live_drafts_and_decisions_stay(self):
        wired = {"decisions": [{"id": "hold-1"}], "tickets": [{"identifier": "IN-1"}], "warnings": ["Card analysis is 9 days old (board x)", "w"],
                 "mrs": [{"ref": "x !1", "url": U + "1", "drafts": [{"id": "f1"}], "actions": [{"id": "row-x-1.comment-f1"}, {"id": "row-x-1.wait-what"}]},
                         {"ref": "x !2", "url": U + "2", "drafts": [], "actions": []},
                         {"ref": "x !3", "url": U + "3", "drafts": [{"id": "d0"}], "actions": [{"id": "row-x-3.comment-d0"}]}]}
        live = {"mrs": [{"ref": "x !1", "url": U + "1/", "drafts": [], "actions": [{"id": "mr-x-1.merge"}]}], "tickets": [{"identifier": "IN-2"}]}
        feed, side = wire.merge_live(wired, {"actions": {"row-x-1.comment-f1": {}}}, live, {"actions": {"mr-x-1.merge": {}}})
        self.assertEqual([m["ref"] for m in feed["mrs"]], ["x !1", "x !3"])  # merged x !2 gone, draft-only card kept
        self.assertEqual([a["id"] for a in feed["mrs"][0]["actions"]], ["row-x-1.comment-f1", "mr-x-1.merge"])
        self.assertEqual(([t["identifier"] for t in feed["tickets"]], feed["decisions"], feed["warnings"]), (["IN-2"], [{"id": "hold-1"}], ["w"]))
        self.assertEqual(set(side["actions"]), {"row-x-1.comment-f1", "mr-x-1.merge"})


if __name__ == "__main__":
    unittest.main()
