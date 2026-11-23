#!/usr/bin/env python3
"""Feed freshness check: wake the ShipDeck owner agent when feed.json is older than 30 minutes. Stdlib only.

  freshness.py [--feed FILE] [--max-age-minutes 30] [--state FILE] [--notify-home FM_HOME]

See docs/shipdeck-wire.md for watcher setup and notification behavior.
"""
import argparse, json, os, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
WIRE = Path(os.environ.get("SHIPDECK_WIRE_HOME") or HERE.parent).expanduser()
SUPPORT = Path(os.environ.get("SHIPDECK_COMPANION", "~/Library/Application Support/ModelDeck/companion")).expanduser()
MAX_AGE_MINUTES = 30


def parse_time(text):
    return datetime.fromisoformat(str(text).replace("Z", "+00:00")).astimezone(timezone.utc)


def check(feed_path, max_age_minutes=MAX_AGE_MINUTES, now=None):
    """(stale, generated_at or None, message). A missing, unreadable or undated feed counts as stale."""
    now = now or datetime.now(timezone.utc)
    try:
        generated = json.loads(Path(feed_path).read_text())["generated_at"]
        age = (now - parse_time(generated)).total_seconds() / 60
    except (OSError, ValueError, KeyError, TypeError) as e:
        return True, None, f"ShipDeck feed unreadable ({feed_path}): {str(e)[:120]}"
    if age <= max_age_minutes:
        return False, generated, ""
    return True, generated, (f"ShipDeck feed is stale: generated {generated}, {int(age)} min ago (limit {max_age_minutes:g}). "
                             "Check the feed job (wire.py feed-job, state/feed.status.json and feed-job.log).")


def notify(home, generated, message):
    """One fm-inbox note per stale feed in that home (the request id makes a repeat a no-op). Returns an error text or None."""
    tool = Path(home).expanduser() / "bin" / "fm-inbox.sh"
    try:
        r = subprocess.run([str(tool), "note", "--request-id", f"shipdeck-stale-{generated or 'unreadable'}", "--json", "-"],
                           input=message + "\n", capture_output=True, text=True, timeout=25,
                           env={**os.environ, "FM_HOME": str(Path(home).expanduser())})
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"fm-inbox note failed: {e}"
    return None if r.returncode in (0, 3) else f"fm-inbox note failed ({r.returncode}): {r.stderr.strip()[:120]}"


def main(argv=None, now=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--feed", default=str(SUPPORT / "feed.json"))
    ap.add_argument("--max-age-minutes", type=float, default=MAX_AGE_MINUTES)
    ap.add_argument("--state", default=str(WIRE / "state" / "freshness.json"))
    ap.add_argument("--notify-home", default=os.environ.get("SHIPDECK_OWNER_HOME"))
    a = ap.parse_args(argv)
    stale, generated, message = check(a.feed, a.max_age_minutes, now)
    state = Path(a.state)
    try:
        reported = json.loads(state.read_text()).get("reported")
    except (OSError, ValueError, AttributeError):
        reported = None
    if not stale:
        if reported is not None:
            state.parent.mkdir(parents=True, exist_ok=True)
            state.write_text(json.dumps({"reported": None}))
        return 0
    key = generated or "unreadable"
    if reported == key:
        return 0  # this stale feed already woke the owner
    if a.notify_home:
        err = notify(a.notify_home, generated, message)
        if err:
            print(f"{message} Notifying {a.notify_home} failed: {err}")
            return 1  # not recorded: the next run tries the note again
    print(message)
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({"reported": key}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
