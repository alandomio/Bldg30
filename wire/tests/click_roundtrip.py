#!/usr/bin/env python3
"""Click round trip (test B): companion-click.v1 files in an inbox folder go through the real click pipe (wire.clicks) in a
temporary firstmate home with a stub bin/fm-inbox.sh, then firstmate acknowledges each note and replies to it. The report
says, per click, which work item the note names and how far it got.

Used by test_click_roundtrip.py (clicks built like the app builds them) and by the Swift ClickRoundTripTests (clicks the
app's own code wrote):  click_roundtrip.py --inbox DIR --feed FEED.json --actions ACTIONS.json [--commands FILE]
-> JSON report on stdout. With --commands the pipe appends its command states to that file (the app passes the
commands.jsonl it reads, beside the inbox) and writes replies beside the inbox. Otherwise both use a temporary folder.
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
        home, officer, support = root / "fmhome", root / "officer", root / "support"
        homes = {"main": home, "deck_officer": officer}
        for directory in homes.values():
            (directory / "bin").mkdir(parents=True)
            _tool(directory / "bin" / "fm-inbox.sh", STUB)
        (home / "state").mkdir()
        for task in ("finished-worker", "running-worker"):
            (home / "state" / f"{task}.meta").write_text("kind=scout\n")
        support.mkdir()
        _tool(home / "bin" / "fm-captain-hold.sh", NOT_A_HOLD)
        shutil.copy(feed_path, support / "feed.json")
        shutil.copy(actions_path, support / "feed.actions.json")
        wire.FM_HOME, wire.SUPPORT, wire.FEED, wire.INBOX = home, support, support / "feed.json", inbox
        wire.REPLIES = (inbox.parent if commands else support) / "replies"
        wire.STATE = root / "state"
        wire.COMMANDS = Path(commands) if commands else support / "commands.jsonl"
        wire.DECK_OFFICER_HOME, wire.HOLD_SH, wire.live = officer, home / "bin" / "fm-captain-hold.sh", lambda: 0
        notes = {name: directory / "state" / "inbox" for name, directory in homes.items()}
        try:
            runs = []
            with redirect_stdout(sys.stderr):
                runs.append(wire.clicks())  # 1: each click becomes a firstmate note, the click moves to handled/
                for directory in notes.values():  # 2: firstmate acknowledges every note
                    for n in sorted(directory.glob("*.note")):
                        os.replace(n, directory / "handled" / n.name)
                runs.append(wire.clicks())
                filed = {}
                for home_name, directory in notes.items():  # 3: firstmate replies to every note
                    for n in sorted((directory / "handled").glob("*.note")):
                        body = n.read_text()
                        key = next(line.removeprefix("Idempotency key: ") for line in body.splitlines()
                                   if line.startswith("Idempotency key: "))
                        filed.setdefault(key, {})[home_name] = body
                        (directory / "replies" / f"{n.stem}.txt").write_text(f"done: {home_name} {key}")
                runs.append(wire.clicks())
            seen = json.loads((wire.STATE / "clicks.json").read_text()) if (wire.STATE / "clicks.json").exists() else {}
            commands = [json.loads(l) for l in wire.COMMANDS.read_text().splitlines()] if wire.COMMANDS.exists() else []
            status = json.loads((wire.STATE / "clicks.status.json").read_text())
            report = {"runs": runs, "errors": status.get("message", ""), "clicks": {}}
            for name, click in clicks.items():
                key = click.get("idempotency_key", "")
                rec = seen.get(key, {})
                note_homes = filed.get(key, {})
                body = next(iter(note_homes.values()), "")
                reply = wire.REPLIES / f"{key}.json"
                response = json.loads(reply.read_text()) if reply.exists() else {}
                report["clicks"][name] = {
                    "action_id": click.get("action_id"), "target": click.get("target"),
                    "filed": bool(rec and note_homes), "note_head": body.splitlines()[0] if body else "",
                    "note_homes": list(note_homes),
                    "stale": "not in feed.actions.json" in body, "note": body,
                    "states": [c["state"] for c in commands if c["id"] == key],
                    "reply": response.get("status"), "reply_text": response.get("text"),
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
