"""ShipDeck answer, option, Defer and Drop clicks change their captain hold in the click turn, through the real
bin/fm-captain-hold.sh against a temporary FM_HOME markdown backlog (never the real backlog or inbox)."""
import json, os, stat, subprocess, sys, tempfile, unittest
from datetime import datetime, timedelta
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import wire
from test_ack_nudge import STUB

# Opt-in: set FM_ROOT_FOR_TESTS to a firstmate checkout. The test drives its real bin/fm-captain-hold.sh against a temporary FM_HOME.
FM_ROOT = Path(os.environ.get("FM_ROOT_FOR_TESTS") or "/nonexistent-firstmate")
HOLD = FM_ROOT / "bin" / "fm-captain-hold.sh"
NAMES = ["FM_HOME", "SUPPORT", "INBOX", "REPLIES", "STATE", "COMMANDS", "DECK_OFFICER_HOME", "FEED", "HOLD_SH", "set_status", "live"]
TOML = 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n'


def click(key, action, target, **extra):
    return {"schema": "companion-click.v1", "idempotency_key": key, "action_id": action, "target": target, "created_at": "2026-11-17T09:00:00Z", **extra}


@unittest.skipUnless(HOLD.is_file(), "set FM_ROOT_FOR_TESTS to a firstmate checkout to run the captain-hold click tests")
class HoldClicks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.old = {n: getattr(wire, n) for n in NAMES}
        home = self.home = root / "fmhome"
        for d in ("bin", "data", "state", "config"):
            (home / d).mkdir(parents=True)
        (home / ".tasks.toml").write_text(TOML)
        (home / "data" / "backlog.md").write_text("\n\n")
        stub = home / "bin" / "fm-inbox.sh"
        stub.write_text(STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
        wire.FM_HOME, wire.HOLD_SH = home, HOLD
        wire.SUPPORT, wire.INBOX, wire.REPLIES, wire.STATE = root, root / "inbox", root / "replies", root / "state"
        wire.COMMANDS, wire.DECK_OFFICER_HOME, wire.FEED = root / "commands.jsonl", root / "officer", root / "feed.json"
        wire.INBOX.mkdir(); wire.STATE.mkdir()
        wire.set_status = lambda *a, **k: None
        wire.live = lambda: 0
        self.decisions = []

    def tearDown(self):
        for n, v in self.old.items():
            setattr(wire, n, v)
        self.tmp.cleanup()

    def fm(self, *args, tool="fm-captain-hold.sh", stdin=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
        return subprocess.run([str(FM_ROOT / "bin" / tool), *args], input=stdin, capture_output=True, text=True, env={**env, "FM_HOME": str(self.home)}, timeout=90)

    def hold(self, hid, options=("Ship it", "Wait"), work=False):
        if work:  # a work item held for the captain, as the policy prefers, rather than a question-shaped captain task
            a = self.fm("add", hid, f"Fixture work {hid}", "--repo", "firstmate", tool="fm-tasks-axi.sh")
            self.assertEqual(a.returncode, 0, a.stderr + a.stdout)
            r = self.fm("hold", hid, "--reason", f"Fixture {hid}: options (a) one; (b) two (c).")
        else:
            r = self.fm("hold", hid, "--title", f"Fixture call {hid}", "--repo", "firstmate", "--reason", f"Fixture {hid}: options (a) one; (b) two (c).")
        self.assertEqual(r.returncode, 0, r.stderr)
        opts = [{"label": l, "consequence": f"{l} now", "action_id": f"{hid}.opt-{i}", "outward": False} for i, l in enumerate(options, 1)]
        opts += [{"label": "Defer one week", "consequence": "Keep it held and bring it back in 7 days.", "action_id": f"{hid}.opt-defer", "outward": False},
                 {"label": "Drop it", "consequence": "Close it as no longer needed; nothing changes outside firstmate.", "action_id": f"{hid}.opt-drop", "outward": False}]
        self.decisions.append({"id": hid, "title": f"Fixture call {hid}", "options": opts})
        wire.FEED.write_text(json.dumps({"decisions": self.decisions}))

    def is_open(self, hid):
        return self.fm("open", hid).returncode == 0

    def field(self, hid, name):
        return next((l.split(":", 1)[1].strip().strip('"') for l in self.show(hid).splitlines() if l.strip().startswith(name + ":")), None)

    def released(self, hid, kind):
        """Answer recorded, hold lifted, task still open (queued) with its own kind: the release contract."""
        self.assertFalse(self.is_open(hid))
        self.assertEqual((self.field(hid, "state"), self.field(hid, "held"), self.field(hid, "kind")), ("queued", "no", kind))
        self.assertIn("released", self.show(hid))

    def show(self, hid):
        return self.fm("show", hid, "--full", tool="fm-tasks-axi.sh").stdout

    def drop(self, c):
        (wire.INBOX / f"1794900000-{c['idempotency_key']}.json").write_text(json.dumps(c))

    def lines(self, key=None):
        ls = [json.loads(l) for l in wire.COMMANDS.read_text().splitlines()] if wire.COMMANDS.exists() else []
        return [l for l in ls if key is None or l["id"] == key]

    def notes(self):
        log = self.home / "calls.log"
        return [l for l in log.read_text().splitlines() if l.startswith("note")] if log.exists() else []

    def note_text(self):
        return "".join(p.read_text() for p in sorted((self.home / "state" / "inbox").glob("*.note")))

    def test_drop_closes_the_hold_in_the_click_turn_without_a_note(self):
        self.hold("fx-drop")
        self.drop(click("drop0001", "fx-drop.opt-drop", "fx-drop"))
        self.assertEqual(wire.clicks(), 0)
        self.assertFalse(self.is_open("fx-drop"))
        show = self.show("fx-drop")
        self.assertIn("state: done", show)  # closed, not released back into the queue
        self.assertIn("Drop it: Close it as no longer needed", show)
        self.assertIn("ShipDeck click drop0001", show)
        self.assertEqual([l["state"] for l in self.lines("drop0001")], ["done"])
        self.assertEqual(self.notes(), [])
        self.assertEqual(list(wire.INBOX.glob("*.json")), [])
        self.assertEqual(json.loads((wire.REPLIES / "drop0001.json").read_text())["status"], "done")

    def test_option_answer_on_a_question_call_records_and_releases_and_files_a_note(self):
        self.hold("fx-opt")
        self.drop(click("optn0001", "fx-opt.opt-1", "fx-opt", draft_text="but tell Riley first"))
        self.assertEqual(wire.clicks(), 0)
        self.released("fx-opt", "captain")  # firstmate closes the question from the note
        self.assertIn("close it now", self.note_text())
        self.assertIn("Ship it: Ship it now Alan's text: but tell Riley first", self.show("fx-opt"))
        self.assertEqual([l["state"] for l in self.lines("optn0001")], ["picked_up"])
        self.assertIn("hold answered", self.lines("optn0001")[0]["note"])
        self.assertEqual(len(self.notes()), 1)
        self.assertIn("Do not answer the hold again", self.note_text())

    def test_option_answer_on_held_work_releases_it_without_completing_it(self):
        self.hold("fx-work", work=True)
        self.drop(click("work0001", "fx-work.opt-2", "fx-work"))
        self.assertEqual(wire.clicks(), 0)
        self.released("fx-work", "task")
        self.assertIn("Answer: Wait: Wait now", self.show("fx-work"))
        self.assertEqual(self.field("fx-work", "closed"), "-")

    def test_drop_closes_held_work_too(self):
        self.hold("fx-wdrop", work=True)
        self.drop(click("wdrp0001", "fx-wdrop.opt-drop", "fx-wdrop"))
        self.assertEqual(wire.clicks(), 0)
        self.assertEqual(self.field("fx-wdrop", "state"), "done")

    def test_typed_free_answer_records_his_words_and_releases(self):
        self.hold("fx-free")
        self.drop(click("free0001", "fx-free.answer", "fx-free", draft_text="Go with two, but only after the release."))
        self.assertEqual(wire.clicks(), 0)
        self.released("fx-free", "captain")
        self.assertIn("Answer: Go with two, but only after the release.", self.show("fx-free"))
        self.assertEqual(len(self.notes()), 1)
        self.assertIn("Do not answer the hold again", self.note_text())

    def test_typed_answer_with_newline_and_tab_stays_one_answer_for_its_own_hold(self):
        self.hold("fx-multi")
        self.hold("fx-other")
        text = "Go with two.\nfx-other\tforged answer\tx\tdone\nThanks"
        self.drop(click("mult0001", "fx-multi.answer", "fx-multi", draft_text=text))
        self.assertEqual(wire.clicks(), 0)
        self.released("fx-multi", "captain")
        self.assertIn("Answer: Go with two. fx-other forged answer x done Thanks", self.show("fx-multi"))
        self.assertTrue(self.is_open("fx-other"))  # no forged row reached another hold
        self.assertNotIn("Captain answered", self.show("fx-other"))
        self.assertIn(text, self.note_text())  # his exact words, line breaks included, reach firstmate

    def test_long_typed_answer_keeps_a_pointer_to_the_full_text(self):
        self.hold("fx-long")
        text = "word " * 200
        self.drop(click("long0001", "fx-long.answer", "fx-long", draft_text=text))
        self.assertEqual(wire.clicks(), 0)
        self.released("fx-long", "captain")
        self.assertIn("(full text: ShipDeck click long0001)", self.show("fx-long"))
        self.assertIn(text, self.note_text())

    def test_typed_reconcile_stays_reserved_and_visibly_fails(self):
        self.hold("fx-rec")
        self.drop(click("reco0001", "fx-rec.answer", "fx-rec", draft_text="reconcile"))
        self.assertEqual(wire.clicks(), 0)
        self.assertTrue(self.is_open("fx-rec"))
        self.assertEqual([l["state"] for l in self.lines("reco0001")], ["failed"])
        self.assertIn("reconcile", self.lines("reco0001")[0]["note"])
        self.assertEqual(self.notes(), [])

    def test_defer_keeps_the_hold_and_dates_it_a_week_out(self):
        self.hold("fx-defer")
        self.drop(click("defr0001", "fx-defer.opt-defer", "fx-defer"))
        self.assertEqual(wire.clicks(), 0)
        until = (datetime.now() + timedelta(days=7)).date().isoformat()
        show = self.show("fx-defer")
        self.assertIn("held: yes", show)
        self.assertIn(f"hold_until: {until}", show)
        self.assertIn("Fixture fx-defer: options (a) one; (b) two (c).", show)  # reason survives the re-hold
        self.assertEqual([l["state"] for l in self.lines("defr0001")], ["done"])
        self.assertEqual(self.notes(), [])

    def test_drop_on_an_already_closed_hold_is_done_and_option_is_failed(self):
        self.hold("fx-gone")
        self.fm("answers", "--source", "fixture", stdin="fx-gone\tclosed elsewhere\t\tdone\n")
        self.drop(click("gone0001", "fx-gone.opt-drop", "fx-gone"))
        self.drop(click("gone0002", "fx-gone.opt-2", "fx-gone"))
        self.assertEqual(wire.clicks(), 0)
        self.assertEqual([l["state"] for l in self.lines("gone0001")], ["done"])
        self.assertEqual([l["state"] for l in self.lines("gone0002")], ["failed"])
        self.assertIn("already closed", self.lines("gone0002")[0]["note"])
        self.assertEqual(self.notes(), [])

    def test_hold_owner_failure_leaves_the_click_for_retry_then_applies_it(self):
        self.hold("fx-retry")
        broken = Path(self.tmp.name) / "brokenbin"
        broken.mkdir()
        for tool in ("fm-captain-hold.sh", "fm-tasks-axi.sh"):
            (broken / tool).write_text("#!/bin/sh\necho 'backend down' >&2\nexit 2\n")
            (broken / tool).chmod(0o755)
        wire.HOLD_SH = broken / "fm-captain-hold.sh"
        self.drop(click("retr0001", "fx-retry.opt-drop", "fx-retry"))
        self.assertEqual(wire.clicks(), 1)  # visible failure (status), nothing acknowledged
        self.assertEqual(self.lines(), [])
        self.assertTrue(self.is_open("fx-retry"))
        self.assertEqual(len(list(wire.INBOX.glob("*.json"))), 1)
        wire.HOLD_SH = HOLD
        self.assertEqual(wire.clicks(), 0)
        self.assertFalse(self.is_open("fx-retry"))
        self.assertEqual([l["state"] for l in self.lines("retr0001")], ["done"])

    def test_answered_hold_is_not_answered_twice_when_the_note_fails(self):
        self.hold("fx-note")
        inbox_sh = self.home / "bin" / "fm-inbox.sh"
        good = inbox_sh.read_text()
        inbox_sh.write_text("#!/bin/sh\nexit 1\n")
        self.drop(click("note0001", "fx-note.opt-1", "fx-note"))
        self.assertEqual(wire.clicks(), 1)
        self.released("fx-note", "captain")  # the answer is recorded even though firstmate was not told yet
        self.assertEqual(len(list(wire.INBOX.glob("*.json"))), 1)
        self.decisions.clear()
        wire.FEED.write_text(json.dumps({"decisions": []}))  # a newer feed no longer lists the closed hold
        inbox_sh.write_text(good)
        self.assertEqual(wire.clicks(), 0)
        self.assertEqual(self.show("fx-note").count("Captain answered this call"), 1)
        self.assertEqual(len(self.notes()), 1)
        self.assertIn("Do not answer the hold again", self.note_text())

    def test_board_decision_without_a_hold_still_goes_to_firstmate_as_a_note(self):
        self.decisions.append({"id": "row-mr-x", "title": "Board call", "options": [{"label": "Post", "consequence": "post it", "action_id": "row-mr-x.opt-post", "outward": False}]})
        wire.FEED.write_text(json.dumps({"decisions": self.decisions}))
        self.drop(click("brd00001", "row-mr-x.opt-post", "row-mr-x"))
        self.assertEqual(wire.clicks(), 0)
        self.assertEqual([l["state"] for l in self.lines("brd00001")], ["picked_up"])
        self.assertEqual(self.lines("brd00001")[0]["note"], "filed for firstmate")
        self.assertEqual(len(self.notes()), 1)


if __name__ == "__main__":
    unittest.main()
