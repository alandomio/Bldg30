"""Held decision Options bullets, using the read-only shipdeck-skill card captured on 2026-11-24.
The feed fixture is shared with Swift's button and click round-trip tests. No live home or service is used.
"""
import json, sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))
import feed

FEEDS = Path(__file__).resolve().parent.parent / "fixtures" / "feeds"


class DecisionOptions(unittest.TestCase):
    def card(self, reason):
        return feed.hold_decision({"id": "fixture", "hold_reason": reason})

    def specific(self, card):
        return [o for o in card["options"] if not o.get("standard")]

    def test_shipdeck_skill_card_matches_shared_feed(self):
        row = json.loads((FEEDS / "shipdeck-skill.hold.json").read_text())
        doc = json.loads((FEEDS / "shipdeck-skill.feed.json").read_text())
        card = feed.hold_decision(row)
        self.assertEqual(doc["decisions"], [card])
        self.assertEqual(feed.validate(doc, feed.load_schema("companion-feed.v1")), [])
        self.assertEqual([o["label"] for o in self.specific(card)], ["Discard the copy (close the worker)", "Keep it"])
        self.assertEqual([o["consequence"] for o in self.specific(card)], [
            "the unpushed commit is dropped; nothing is lost, its content is already on main.",
            "the old worker session stays open and keeps using memory, with nothing left to do."])
        self.assertEqual(card["recommendation"], "discard the copy, since main already has every file.")
        self.assertTrue(card["why_now"].startswith("Old copy of the ShipDeck skill work:"))
        self.assertEqual([o["action_id"] for o in card["options"]],
                         ["shipdeck-skill.opt-1", "shipdeck-skill.opt-2", "shipdeck-skill.opt-defer", "shipdeck-skill.opt-drop"])

    def test_first_colon_only_and_full_labels_and_recommendation_survive(self):
        label = "Keep all of the current files and close the old worker (after review)"
        card = self.card(f"Context.\nOptions:\n- {label}: Check status: keep it; or archive it.\n"
                         "Recommendation: Keep all files. Close the worker after review.")
        self.assertEqual([(o["label"], o["consequence"]) for o in self.specific(card)],
                         [(label, "Check status: keep it; or archive it.")])
        self.assertEqual(card["recommendation"], "Keep all files. Close the worker after review.")

    def test_only_options_section_bullets_become_buttons(self):
        card = self.card("Title: A decision\nSummary:\n- State: Waiting\n- Risk: Small\n"
                         "Options:\n- A: Proceed\n- B: Wait\nRecommendation: A\nLinks:\n- https://example.com/report")
        self.assertEqual([o["label"] for o in self.specific(card)], ["A", "B"])

    def test_no_options_section_does_not_invent_buttons(self):
        for reason in ("Waiting; or ready.", "- A: Proceed\n- B: Wait\nRecommendation: Wait.",
                       "Choose later.\nRecommendation: Wait.", "Options:\nRecommendation: Wait.",
                       "There are options for next week; or later."):
            with self.subTest(reason=reason):
                card = self.card(reason)
                self.assertEqual(self.specific(card), [])
                self.assertEqual([o["label"] for o in card["options"]], ["Defer one week", "Drop it"])

    def test_escaped_newlines_and_numbered_list_options(self):
        card = self.card("Context\\nOptions:\\n- Ship: Done\\n- Wait: Held\\nRecommendation: Ship")
        self.assertEqual([o["label"] for o in self.specific(card)], ["Ship", "Wait"])
        inline = self.card("Why now: Ready.\nOptions:\n(1) Ship now: Done.\n(2) Wait until Friday: Held.\nRecommendation: (1).")
        self.assertEqual([o["label"] for o in self.specific(inline)], ["Ship now", "Wait until Friday"])


if __name__ == "__main__":
    unittest.main()
