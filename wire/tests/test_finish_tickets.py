import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import live_state


class FinishTickets(unittest.TestCase):
    def board(self):
        return {"tickets": [{"id": "IN-1", "mr": "pi !1", "label": "Merge !1"}, {"id": "IN-2", "mr": "pi !2"}],
                "mrs": [{"refs": [["https://g/1", "pi !1", "t"]], "ticket": "IN-1"},
                        {"refs": [["https://g/2", "pi !2", "t"]], "ticket": "IN-2"}]}

    def test_merged_mr_gives_ticket_verify_and_close(self):
        b = self.board()
        dropped, _, _ = live_state.prune_board(b, {"https://g/2"}, lambda u: "merged")
        self.assertEqual(dropped, ["pi !1"])
        t1, t2 = b["tickets"]
        self.assertEqual([a["label"] for a in t1["actions"]], ["Verify and close"])
        self.assertIn("pi !1 merged", t1["next"])
        self.assertNotIn("actions", t2)

    def test_ticket_with_own_action_is_left_alone(self):
        b = self.board()
        b["tickets"][0]["actions"] = [{"label": "Do it", "prompt": "x"}]
        live_state.prune_board(b, set(), lambda u: "merged")
        self.assertEqual([a["label"] for a in b["tickets"][0]["actions"]], ["Do it"])

    def test_decision_ref_to_finished_mr_is_cleared(self):
        b = self.board()
        b["tickets"][1]["decision_ref"] = "pi !1"
        live_state.prune_board(b, {"https://g/2"}, lambda u: "merged")
        self.assertNotIn("decision_ref", b["tickets"][1])
        self.assertEqual(b["tickets"][1]["label"], "pi !1 merged: re-check")


if __name__ == "__main__":
    unittest.main()
