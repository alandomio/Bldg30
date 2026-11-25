"""Decision review regressions. All owner and inbox calls are stubbed in temporary homes."""
import copy, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
os.environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))
import feed, render, wire

FIXTURES = Path(__file__).resolve().parent / "fixtures"
ROW = json.loads((FIXTURES.parent.parent / "fixtures/feeds/shipdeck-skill.hold.json").read_text())


class StrictOptions(unittest.TestCase):
    def card(self, reason):
        return feed.hold_decision({"id": "fixture", "hold_reason": reason})

    def test_prose_with_options_colon_is_not_a_section(self):
        card = self.card((FIXTURES / "options-in-prose.txt").read_text())
        self.assertEqual([o["label"] for o in card["options"]], ["Defer one week", "Drop it"])

    def test_numbered_lines_are_structural_and_semicolons_stay_in_consequences(self):
        for text in ((FIXTURES / "options-numbered-prose.txt").read_text(),
                     "Context.\nOptions:\n(1) Ship: Ready; retain old files.\n(2) Wait: Delay.\nRecommendation: Ship"):
            with self.subTest(text=text):
                options = [o for o in self.card(text)["options"] if not o.get("standard")]
                self.assertEqual([(o["label"], o["consequence"]) for o in options], [("Ship", "Ready; retain old files."), ("Wait", "Delay.")])

    def test_unsupported_inline_text_does_not_create_choices(self):
        for text in ("Options: Ship; Wait.\nRecommendation: Ship", "Options:\nShip; Wait.\nRecommendation: Ship",
                     "Context. Options: (1) Ship; (2) Wait. Recommendation: Ship"):
            with self.subTest(text=text):
                self.assertTrue(all(o.get("standard") for o in self.card(text)["options"]))

    def test_six_bullets_are_reported_and_no_choices_are_silently_dropped(self):
        reason = "Context.\nOptions:\n" + "\n".join(f"- Choice {n}: Consequence {n}." for n in range(6)) + "\nRecommendation: Choice 0"
        card = self.card(reason)
        self.assertIn("6 options", card.get("validation_error", ""))
        self.assertIn("5", card["validation_error"])
        self.assertEqual([o["label"] for o in card["options"]], ["Defer one week", "Drop it"])
        self.assertEqual(card["full_context"], reason)
        doc, _ = feed.build(render, {"date": "2026-11-24"}, [], [], [], "fixture", holds=[card])
        self.assertIn(card["validation_error"], doc["warnings"][0])


class StaleOptionClicks(unittest.TestCase):
    def original(self):
        return feed.hold_decision(ROW)

    def click(self, card, text="", index=0):
        option = card["options"][index]
        click = {"schema": "companion-click.v1", "idempotency_key": "option-safety-0001", "action_id": option["action_id"],
                 "target": card["id"], "created_at": "2026-11-24T18:00:00Z",
                 "selected_option": {"label": option["label"], "consequence": option["consequence"], "index": index}}
        if text:
            click["draft_text"] = text
        return click

    def process(self, card, click, check):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inbox = root / "inbox"; inbox.mkdir()
            (root / "state").mkdir()
            (root / "feed.json").write_text(json.dumps({"decisions": [card]}))
            (inbox / "1795000000-option-safety-0001.json").write_text(json.dumps(click))
            def owner(args, body=None, **kwargs):
                return subprocess.CompletedProcess(args, 0, stdout="closed: shipdeck-skill\n" if args[0] == "answers" else "", stderr="")
            with mock.patch.multiple(wire, FM_HOME=root, SUPPORT=root, FEED=root / "feed.json", INBOX=inbox,
                                     REPLIES=root / "replies", STATE=root / "state", COMMANDS=root / "commands.jsonl"), \
                 mock.patch.object(wire, "run_hold", side_effect=owner) as hold, \
                 mock.patch.object(wire, "run_inbox", return_value=subprocess.CompletedProcess([], 0, stdout='{"id":"note-1"}', stderr="")) as note, \
                 mock.patch.object(wire, "mirror_receipts", return_value=[]), mock.patch.object(wire, "live", return_value=0), \
                 mock.patch.object(wire, "set_status"):
                self.assertEqual(wire.clicks(), 0)
                check(root, hold, note)

    def test_refresh_reorder_and_changed_meaning_are_visibly_refused_before_owner_calls(self):
        original = self.original()
        for mutation in ("reorder", "label", "consequence", "removed", "missing-snapshot", "wrong-target", "position"):
            for context in ("", "After review."):
                with self.subTest(mutation=mutation, context=context):
                    fresh = copy.deepcopy(original)
                    click = self.click(original, context)
                    if mutation == "reorder":
                        fresh["options"][:2] = list(reversed(fresh["options"][:2]))
                        for i, option in enumerate(fresh["options"][:2], 1):
                            option["action_id"] = f"shipdeck-skill.opt-{i}"
                    elif mutation in ("label", "consequence"):
                        fresh["options"][0][mutation] += " Changed."
                    elif mutation == "removed":
                        fresh["options"].pop(0)
                    elif mutation == "missing-snapshot":
                        click.pop("selected_option")
                    elif mutation == "wrong-target":
                        click["target"] = "another-hold"
                    else:
                        fresh["options"][:2] = list(reversed(fresh["options"][:2]))  # even if IDs stay stable
                    def refused(root, hold, note):
                        hold.assert_not_called()
                        note.assert_not_called()
                        reply = json.loads((root / "replies/option-safety-0001.json").read_text())
                        self.assertEqual(reply["status"], "rejected")
                        self.assertIn("option", reply["text"].lower())
                        lines = [json.loads(line) for line in (root / "commands.jsonl").read_text().splitlines()]
                        self.assertEqual([line["state"] for line in lines], ["failed"])
                    self.process(fresh, click, refused)

    def test_unchanged_selection_and_context_reach_the_owner_separately(self):
        original = self.original()
        for context in ("", "After review."):
            with self.subTest(context=context):
                def accepted(root, hold, note):
                    answer = next(call for call in hold.call_args_list if call.args[0][0] == "answers")
                    words = answer.args[1].split("\t")[1]
                    self.assertTrue(words.startswith("Discard the copy (close the worker): the unpushed commit is dropped;"))
                    if context:
                        self.assertTrue(words.endswith("Alan's text: After review."))
                    else:
                        self.assertNotIn("Alan's text:", words)
                    note.assert_called_once()
                self.process(original, self.click(original, context), accepted)

    def test_apply_hold_rechecks_even_when_the_caller_supplies_an_old_option(self):
        original = self.original()
        click = self.click(original, "After review.")
        fresh = copy.deepcopy(original)
        fresh["options"][0]["consequence"] = "A changed consequence."
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "feed.json"
            path.write_text(json.dumps({"decisions": [fresh]}))
            with mock.patch.multiple(wire, FEED=path, STATE=root), mock.patch.object(wire, "run_hold") as owner:
                state, text, filed = wire.apply_hold(click, original, original["options"][0])
                self.assertEqual(state, "failed")
                self.assertFalse(filed)
                self.assertIn("option", text)
                owner.assert_not_called()

    def test_answered_click_keeps_its_recorded_choice_when_the_note_is_retried(self):
        original = self.original()
        click = self.click(original, "After review.")
        fresh = copy.deepcopy(original)
        fresh["options"][0]["label"] = "Keep it"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "feed.json").write_text(json.dumps({"decisions": [fresh]}))
            recorded = {click["idempotency_key"]: {"hold": original["id"], "title": original["title"],
                        "option": original["options"][0], "text": "Already answered."}}
            (root / wire.HOLD_CLICKS).write_text(json.dumps(recorded))
            with mock.patch.multiple(wire, FEED=root / "feed.json", STATE=root), mock.patch.object(wire, "run_hold") as owner:
                text = wire.hold_click(click, root / "click.json", {}, root, [])
                body = wire.click_body(click, {}, text)
                self.assertIn("Alan chose option 'Discard the copy (close the worker)'", body)
                self.assertIn("Do not answer the hold again", body)
                self.assertIn("After review.", body)
                owner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
