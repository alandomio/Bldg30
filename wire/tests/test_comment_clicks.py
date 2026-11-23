import json, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import wire

NAMES = ["SUPPORT", "INBOX", "REPLIES", "STATE", "COMMANDS", "DECK_OFFICER_HOME", "set_status"]


def comment(key="c" * 8):
    return {"schema": "companion-click.v1", "idempotency_key": key, "action_id": "comment_deck_officer", "target": "global",
            "created_at": "2026-11-05T10:00:00Z", "draft_text": "please look at card X"}


class CommentClicks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.old = {n: getattr(wire, n) for n in NAMES}
        wire.SUPPORT, wire.INBOX, wire.REPLIES, wire.STATE = root, root / "inbox", root / "replies", root / "state"
        wire.COMMANDS, wire.DECK_OFFICER_HOME = root / "commands.jsonl", root / "officer"
        wire.INBOX.mkdir(); wire.STATE.mkdir()
        wire.set_status = lambda *a, **k: None

    def tearDown(self):
        for n, v in self.old.items():
            setattr(wire, n, v)
        self.tmp.cleanup()

    receipts = {"pending": [{"id": "n1"}], "handled": [], "replies": []}

    def fake(self, calls):
        def run(args, body=None, home=None):
            calls.append((args, body, home))
            if args[0] == "receipts":
                return mock.Mock(returncode=0, stdout=json.dumps(self.receipts), stderr="")
            return mock.Mock(returncode=0, stdout=json.dumps({"id": "n1"}), stderr="")
        return run

    def test_comment_goes_to_deck_officer_home_with_full_text(self):
        (wire.INBOX / "1-c.json").write_text(json.dumps(comment()))
        calls = []
        with mock.patch.object(wire, "run_inbox", self.fake(calls)):
            wire.clicks()
        note = [c for c in calls if c[0][0] == "note"][0]
        self.assertEqual(note[2], wire.DECK_OFFICER_HOME)
        self.assertIn("please look at card X", note[1])
        self.assertIn("companion-reply.v1", note[1])
        self.assertIn("cccccccc.json", note[1])

    def test_other_click_stays_with_main_home(self):
        c = comment(); c["action_id"] = "nope.x"
        (wire.INBOX / "1-c.json").write_text(json.dumps(c))
        calls = []
        with mock.patch.object(wire, "run_inbox", self.fake(calls)):
            wire.clicks()
        self.assertIsNone([x for x in calls if x[0][0] == "note"][0][2])

    def test_receipt_does_not_overwrite_reply_text(self):
        (wire.INBOX / "1-c.json").write_text(json.dumps(comment()))
        calls = []
        with mock.patch.object(wire, "run_inbox", self.fake(calls)):
            wire.clicks()
            reply = wire.REPLIES / ("c" * 8 + ".json")
            self.assertEqual(json.loads(reply.read_text())["status"], "queued")
            reply.write_text(json.dumps({"schema": "companion-reply.v1", "idempotency_key": "c" * 8, "note_id": "n1",
                                         "status": "done", "text": "Done, see card.", "updated_at": "t"}))
            wire.clicks()
        self.assertEqual(json.loads(reply.read_text())["text"], "Done, see card.")

    def test_reply_from_fm_inbox_in_deck_officer_home_reaches_replies(self):
        (wire.INBOX / "1-c.json").write_text(json.dumps(comment()))
        calls = []
        with mock.patch.object(wire, "run_inbox", self.fake(calls)):
            wire.clicks()
            self.receipts = {"pending": [], "handled": [{"id": "n1"}], "replies": [{"id": "n1", "body": "On it."}]}
            wire.clicks()
        self.assertTrue(any(c[0][0] == "receipts" and c[2] == wire.DECK_OFFICER_HOME for c in calls))
        self.assertEqual(json.loads((wire.REPLIES / ("c" * 8 + ".json")).read_text())["text"], "On it.")

    def test_missing_officer_home_reports_error_and_does_not_block_other_clicks(self):
        (wire.INBOX / "1-c.json").write_text(json.dumps(comment()))
        other = comment("d" * 8); other["action_id"] = "nope.x"
        (wire.INBOX / "2-d.json").write_text(json.dumps(other))
        statuses = []
        wire.set_status = lambda name, ok, message="": statuses.append((name, ok, message))
        calls = []
        ok = self.fake(calls)

        def run(args, body=None, home=None):
            if home == wire.DECK_OFFICER_HOME:
                raise FileNotFoundError("no such home")
            return ok(args, body, home)
        with mock.patch.object(wire, "run_inbox", run):
            self.assertEqual(wire.clicks(), 1)
        self.assertTrue((wire.INBOX / "1-c.json").exists())
        self.assertTrue((wire.INBOX / "handled" / "2-d.json").exists())
        self.assertEqual(statuses[-1][:2], ("clicks", False))
        self.assertIn("1-c.json", statuses[-1][2])


if __name__ == "__main__":
    unittest.main()
