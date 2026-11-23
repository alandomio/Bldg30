"""Acknowledgement mirror and nudge of the click bridge, against a temporary FM_HOME with a stub bin/fm-inbox.sh (never the real inbox)."""
import json, os, stat, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import wire

NAMES = ["FM_HOME", "SUPPORT", "INBOX", "REPLIES", "STATE", "COMMANDS", "DECK_OFFICER_HOME", "set_status", "live"]

# Stub: `note` saves the body as state/inbox/<id>.note and prints {"id"}; `receipts` lists pending and handled/ notes and replies/*.
STUB = r'''#!/bin/bash
set -e
INBOX="$FM_HOME/state/inbox"; mkdir -p "$INBOX/handled" "$INBOX/replies"
echo "$*" >> "$FM_HOME/calls.log"
case "$1" in
  note)
    n=$(ls "$INBOX" | grep -c '\.note$' || true); id="n$((n + $(ls "$INBOX/handled" | wc -l) + 1))"
    cat > "$INBOX/$id.note"; printf '{"id":"%s"}\n' "$id" ;;
  announce) printf '{"id":"%s","announced":true}\n' "$3" ;;
  receipts)
    python3 - "$INBOX" <<'PY'
import json, sys
from pathlib import Path
i = Path(sys.argv[1])
ids = lambda d: [{"id": p.stem} for p in sorted(d.glob("*.note"))]
print(json.dumps({"pending": ids(i), "handled": ids(i / "handled"),
                  "replies": [{"id": p.stem, "body": p.read_text()} for p in sorted((i / "replies").glob("*.txt"))]}))
PY
    ;;
esac
'''


def click(key, action="row-mr-aim-380.comment-d0", target="aim !380", **extra):
    return {"schema": "companion-click.v1", "idempotency_key": key, "action_id": action, "target": target, "created_at": "2026-11-03T17:41:09Z", **extra}


class AckAndNudge(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.old = {n: getattr(wire, n) for n in NAMES}
        home = root / "fmhome"
        (home / "bin").mkdir(parents=True)
        stub = home / "bin" / "fm-inbox.sh"
        stub.write_text(STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
        wire.FM_HOME, self.home = home, home
        wire.SUPPORT, wire.INBOX, wire.REPLIES, wire.STATE = root, root / "inbox", root / "replies", root / "state"
        wire.COMMANDS, wire.DECK_OFFICER_HOME = root / "commands.jsonl", root / "officer"
        wire.INBOX.mkdir(); wire.STATE.mkdir()
        wire.set_status = lambda *a, **k: None
        wire.live = lambda: 0

    def tearDown(self):
        for n, v in self.old.items():
            setattr(wire, n, v)
        self.tmp.cleanup()

    def drop(self, c):
        (wire.INBOX / f"1793727669-{c['idempotency_key']}.json").write_text(json.dumps(c))

    def lines(self):
        return [json.loads(l) for l in wire.COMMANDS.read_text().splitlines()] if wire.COMMANDS.exists() else []

    def seen(self):
        return json.loads((wire.STATE / "clicks.json").read_text())

    def ack(self, note_id):
        inbox = self.home / "state" / "inbox"
        os.replace(inbox / f"{note_id}.note", inbox / "handled" / f"{note_id}.note")

    def test_filed_click_stays_picked_up_until_acknowledged_then_acknowledged_once(self):
        self.drop(click("k" * 8))
        self.assertEqual(wire.clicks(), 0)
        self.assertEqual([l["state"] for l in self.lines()], ["picked_up"])
        wire.clicks()
        self.assertEqual([l["state"] for l in self.lines()], ["picked_up"])  # not acknowledged: no new line
        self.ack(self.seen()["k" * 8]["note_id"])
        wire.clicks(); wire.clicks()
        self.assertEqual([l["state"] for l in self.lines()], ["picked_up", "acknowledged"])  # written once
        self.assertEqual(self.lines()[-1]["note"], "acknowledged by firstmate")

    def test_reply_marks_done_after_acknowledged(self):
        self.drop(click("k" * 8))
        wire.clicks()
        nid = self.seen()["k" * 8]["note_id"]
        self.ack(nid)
        wire.clicks()
        (self.home / "state" / "inbox" / "replies" / f"{nid}.txt").write_text("posted")
        wire.clicks()
        self.assertEqual([l["state"] for l in self.lines()], ["picked_up", "acknowledged", "done"])

    def test_nudge_files_a_fresh_note_pointing_at_the_waiting_one(self):
        self.drop(click("k" * 8))
        wire.clicks()
        nid = self.seen()["k" * 8]["note_id"]
        self.drop(click("u" * 8, action="row-mr-aim-380.comment-d0.nudge", nudges="k" * 8))
        self.assertEqual(wire.clicks(), 0)
        notes = sorted((self.home / "state" / "inbox").glob("*.note"))
        self.assertEqual(len(notes), 2)
        fresh = [p for p in notes if p.stem != nid][0].read_text()
        self.assertTrue(fresh.startswith(f"ShipDeck nudge: click row-mr-aim-380.comment-d0 on aim !380 waits since 2026-11-03T17:41:09Z, original note {nid}"))
        self.assertIn("ShipDeck click:", fresh)  # the original note body follows
        last = self.lines()[-1]
        self.assertEqual((last["id"], last["state"]), ("k" * 8, "picked_up"))
        self.assertTrue(last["note"].startswith("nudged "))
        self.assertNotIn("u" * 8, {l["id"] for l in self.lines()})  # the nudge has no command of its own
        self.assertEqual(json.loads((wire.REPLIES / ("u" * 8 + ".json")).read_text())["status"], "done")
        self.assertTrue((wire.INBOX / "handled" / f"1793727669-{'u' * 8}.json").exists())

    def test_nudge_of_an_acknowledged_click_does_nothing(self):
        self.drop(click("k" * 8))
        wire.clicks()
        self.ack(self.seen()["k" * 8]["note_id"])
        self.drop(click("u" * 8, action="x.nudge", nudges="k" * 8))
        wire.clicks()
        self.assertEqual(len(list((self.home / "state" / "inbox").glob("*.note"))), 0)  # no new note
        self.assertEqual(json.loads((wire.REPLIES / ("u" * 8 + ".json")).read_text())["text"], "already acknowledged")
        self.assertFalse(any(l.get("note", "").startswith("nudged") for l in self.lines()))

    def test_nudge_of_an_unknown_click_is_rejected(self):
        self.drop(click("u" * 8, action="x.nudge", nudges="z" * 8))
        self.assertEqual(wire.clicks(), 0)
        self.assertEqual(json.loads((wire.REPLIES / ("u" * 8 + ".json")).read_text())["status"], "rejected")

    def test_ask_delivery_buddy_files_a_read_only_request_and_the_reply_comes_back(self):
        self.drop(click("b" * 8, action="IN-2593.ask-delivery-buddy", target="IN-2593"))
        self.assertEqual(wire.clicks(), 0)
        nid = self.seen()["b" * 8]["note_id"]
        body = (self.home / "state" / "inbox" / f"{nid}.note").read_text()
        self.assertIn("Ask delivery buddy on IN-2593", body)
        self.assertIn("fm-inbox.sh reply", body)
        self.assertNotIn("treat as stale", body)
        self.ack(nid)
        (self.home / "state" / "inbox" / "replies" / f"{nid}.txt").write_text("Step: review. Next: Riley approves !2040.")
        wire.clicks()
        reply = json.loads((wire.REPLIES / ("b" * 8 + ".json")).read_text())
        self.assertEqual((reply["status"], reply["text"]), ("done", "Step: review. Next: Riley approves !2040."))

    def test_decide_options_files_the_picks_for_firstmate(self):
        text = "Decision on the delivery-buddy options of IN-2420 (card from the run at 2026-11-06T12:30:00Z):\n- mwaa A) park at devops now"
        self.drop(click("d" * 8, action="IN-2420.decide-options", target="IN-2420", draft_text=text))
        self.assertEqual(wire.clicks(), 0)
        body = (self.home / "state" / "inbox" / f"{self.seen()['d' * 8]['note_id']}.note").read_text()
        self.assertIn("Decision on the delivery-buddy options of IN-2420", body)
        self.assertIn("- mwaa A) park at devops now", body)
        self.assertIn("2026-11-06T12:30:00Z", body)
        self.assertNotIn("treat as stale", body)

    def test_a_second_run_while_one_holds_the_lock_returns_at_once(self):
        import fcntl
        with open(wire.STATE / "clicks.lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.drop(click("k" * 8))
            self.assertEqual(wire.clicks(), 0)
            self.assertEqual(self.lines(), [])  # nothing filed by the blocked run


if __name__ == "__main__":
    unittest.main()
