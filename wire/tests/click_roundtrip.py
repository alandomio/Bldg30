#!/usr/bin/env python3
"""Click round trip (test B): companion-click.v1 files in an inbox folder go through the real click pipe (wire.clicks) in a
temporary firstmate home with a stub bin/fm-inbox.sh, then firstmate acknowledges each note and replies to it. The report
says, per click, which work item the note names and how far it got.

Used by test_click_roundtrip.py (clicks built like the app builds them) and by the Swift ClickRoundTripTests (clicks the
app's own code wrote):  click_roundtrip.py --inbox DIR --feed FEED.json --actions ACTIONS.json [--commands FILE]
-> JSON report on stdout. With --commands the pipe appends its command states to that file (the app passes the
commands.jsonl it reads, beside the inbox); without it a temporary one is used. Nothing else outside the given inbox and
a temporary folder is read or written.
"""
import argparse, json, os, shutil, stat, sys, tempfile
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bin"))
sys.path.insert(0, str(HERE))
os.environ["SHIPDECK_ORG_CONFIG"] = str(HERE / "org.test.json")  # hermetic org values
import wire  # noqa: E402
from test_ack_nudge import STUB  # noqa: E402  (stub fm-inbox.sh: notes, receipts, replies under the temporary FM_HOME)

NOT_A_HOLD = "#!/bin/bash\n# Stub fm-captain-hold.sh: every decision here is a board decision, not a captain hold.\nexit 3\n"
NAMES = ["FM_HOME", "SUPPORT", "FEED", "INBOX", "REPLIES", "STATE", "COMMANDS", "DECK_OFFICER_HOME", "HOLD_SH", "live"]


def _tool(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def roundtrip(inbox, feed_path, actions_path, commands=None):
    inbox = Path(inbox)
    clicks = {p.name: json.loads(p.read_text()) for p in sorted(inbox.glob("*.json")) if not p.name.endswith(".reply.json")}
    old = {n: getattr(wire, n) for n in NAMES}
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        home, support = root / "fmhome", root / "support"
        for d in (home / "bin", home / "state", support):
            d.mkdir(parents=True)
        _tool(home / "bin" / "fm-inbox.sh", STUB)
        _tool(home / "bin" / "fm-captain-hold.sh", NOT_A_HOLD)
        shutil.copy(feed_path, support / "feed.json")
        shutil.copy(actions_path, support / "feed.actions.json")
        wire.FM_HOME, wire.SUPPORT, wire.FEED, wire.INBOX = home, support, support / "feed.json", inbox
        wire.REPLIES, wire.STATE = support / "replies", root / "state"
        wire.COMMANDS = Path(commands) if commands else support / "commands.jsonl"
        wire.DECK_OFFICER_HOME, wire.HOLD_SH, wire.live = root / "officer", home / "bin" / "fm-captain-hold.sh", lambda: 0
        notes = home / "state" / "inbox"
        try:
            runs = []
            with redirect_stdout(sys.stderr):
                runs.append(wire.clicks())  # 1: each click becomes a firstmate note, the click moves to handled/
                for n in sorted(notes.glob("*.note")):  # 2: firstmate acknowledges every note
                    os.replace(n, notes / "handled" / n.name)
                runs.append(wire.clicks())
                for n in sorted((notes / "handled").glob("*.note")):  # 3: firstmate replies to every note
                    (notes / "replies" / f"{n.stem}.txt").write_text(f"done: {n.read_text().splitlines()[0]}")
                runs.append(wire.clicks())
            seen = json.loads((wire.STATE / "clicks.json").read_text()) if (wire.STATE / "clicks.json").exists() else {}
            commands = [json.loads(l) for l in wire.COMMANDS.read_text().splitlines()] if wire.COMMANDS.exists() else []
            status = json.loads((wire.STATE / "clicks.status.json").read_text())
            report = {"runs": runs, "errors": status.get("message", ""), "clicks": {}}
            for name, click in clicks.items():
                key = click.get("idempotency_key", "")
                rec = seen.get(key, {})
                note = notes / "handled" / f"{rec.get('note_id')}.note"
                body = note.read_text() if rec and note.exists() else ""
                reply = support / "replies" / f"{key}.json"
                report["clicks"][name] = {
                    "action_id": click.get("action_id"), "target": click.get("target"),
                    "filed": bool(rec), "note_head": body.splitlines()[0] if body else "",
                    "stale": "not in feed.actions.json" in body, "note": body,
                    "states": [c["state"] for c in commands if c["id"] == key],
                    "reply": json.loads(reply.read_text()).get("status") if reply.exists() else None,
                    "handled": (inbox / "handled" / name).exists(),
                    "reply_beside": (inbox / "handled" / (Path(name).stem + ".reply.json")).exists()}
            return report
        finally:
            for n, v in old.items():
                setattr(wire, n, v)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--inbox", required=True)
    ap.add_argument("--feed", required=True)
    ap.add_argument("--actions", required=True)
    ap.add_argument("--commands")
    a = ap.parse_args(argv)
    json.dump(roundtrip(a.inbox, a.feed, a.actions, a.commands), sys.stdout, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
