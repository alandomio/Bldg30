#!/usr/bin/env python3
"""Refresh the companion feed without an agent turn: live MR facts and live Linear state onto board.json.
Usage: refresh.py [--board f] [--feed f] [--holds-cmd cmd] [--keychain-service name]; defaults and the key setup are in companion/README.md.
"""
from datetime import date
import argparse, json, os, re, subprocess, sys, tempfile
from pathlib import Path
from urllib import request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import live_state  # local producer addition: live MR state and Linear detail
import approvals  # local producer addition (034): live approvals, Waiting on others
import review_drafts  # local producer addition (033): review comment drafts on the MR card

HERE = Path(__file__).resolve().parent
DEFAULT_FEED = "~/Library/Application Support/ModelDeck/companion/feed.json"
DEFAULT_SERVICE = "companion-linear-readonly"
CLOSED = {"done", "canceled", "cancelled"}
ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*-\d+$")


KEY_PROBLEM = {}


def read_key(service, run=subprocess.run):
    """The Linear key from the Keychain, or None. The value is only ever passed on, never printed.
    When None, KEY_PROBLEM[service] says why (exit code and security's own message, never the value)."""
    r = run(["security", "find-generic-password", "-s", service, "-w"], capture_output=True, text=True)
    key = r.stdout.strip() if r.returncode == 0 else ""
    if key:
        KEY_PROBLEM.pop(service, None)
        return key
    if r.returncode == 0:
        KEY_PROBLEM[service] = "the item exists but its stored value is empty (re-add it with: security add-generic-password -U -s %s -a \"$USER\" -w)" % service
    else:
        KEY_PROBLEM[service] = "security exited %d: %s" % (r.returncode, (r.stderr or "").strip()[:120] or "no message")
    return None


def fetch_linear(key, identifiers, post=None):
    """{identifier: {title, status}} for the given ticket ids, one GraphQL call. Errors never carry the key."""
    ids = sorted({i for i in identifiers if ID_RE.match(i)})
    if not ids:
        return {}
    query = "query{" + " ".join(f'i{n}: issue(id: "{i}") {{ identifier title state {{ name }} }}' for n, i in enumerate(ids)) + "}"
    post = post or _post
    data = post("https://api.linear.app/graphql", {"query": query}, {"Authorization": key, "Content-Type": "application/json"})
    if data.get("errors") and not data.get("data"):
        raise RuntimeError("Linear returned errors: " + "; ".join(str(e.get("message", ""))[:80] for e in data["errors"][:3]))
    return {v["identifier"]: {"title": v["title"], "status": v["state"]["name"]} for v in (data.get("data") or {}).values() if v}


def _post(url, payload, headers):
    req = request.Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
    with request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def overlay_linear(board, live):
    """Put live ticket status and title on the board's ticket rows; a Done or Canceled ticket leaves the board,
    and a merged MR row naming it gets ticket_status so render.py can close it."""
    keep = []
    for t in board.get("tickets", []):
        got = live.get(t["id"])
        if got:
            t["status"] = got["status"]
            t.setdefault("title", got["title"])
            if got["status"].lower() in CLOSED:
                continue
        keep.append(t)
    board["tickets"] = keep
    for m in board.get("mrs", []):
        got = live.get(str(m.get("ticket", "")))
        if got:
            m["ticket_status"] = got["status"]
    return board


def collect(user, runner=subprocess.run):
    """collect_mrs.py --format json output as a dict."""
    cmd = [sys.executable, str(HERE / "collect_mrs.py"), "--format", "json"] + (["--user", user] if user else [])
    r = runner(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("collect_mrs.py failed: " + r.stderr.strip()[:200])
    return json.loads(r.stdout)


def refresh(board_path, feed_path, holds_cmd=None, service=DEFAULT_SERVICE, user=None,
            collect_fn=collect, key_fn=read_key, linear_fn=fetch_linear, render_run=subprocess.run,
            state_fn=live_state.mr_state, detail_fn=live_state.fetch_details, approvals_fn=approvals.fetch):
    """Write the feed from board.json plus live facts. A failed live source is a warning in the feed, not a missing feed."""
    board = json.loads(Path(board_path).expanduser().read_text())
    warnings = []
    try:
        facts = collect_fn(user)
    except Exception as e:
        facts, warnings = {"mrs": []}, warnings + [f"MR facts not refreshed: {e}"]
    # Live MR state: a board row whose MR GitLab says is merged or closed never reaches the feed.
    open_urls = {f["url"].rstrip("/") for f in facts.get("mrs", []) if f.get("state") == "opened" and f.get("url")}
    ref_state = {x["refs"][0][1]: ("opened" if live_state.row_url(x) in open_urls else None) for x in board.get("mrs", []) if x.get("refs")}
    dropped, mr_states, state_warnings = live_state.prune_board(board, open_urls, state_fn)
    warnings += state_warnings
    for x in board.get("mrs", []):
        if x.get("refs"):
            ref_state[x["refs"][0][1]] = mr_states.get(live_state.row_url(x)) or ref_state.get(x["refs"][0][1])
    if dropped:
        print(f"info: {len(dropped)} merged or closed MRs left out of the feed: {', '.join(dropped)}", file=sys.stderr)
    key = key_fn(service)
    details = {}
    if key:
        try:
            overlay_linear(board, linear_fn(key, [t["id"] for t in board.get("tickets", [])] + [str(m["ticket"]) for m in board.get("mrs", []) if m.get("ticket")]))
        except Exception as e:
            warnings.append(f"Linear not refreshed: {str(e).replace(key, '***')[:160]}")
        try:
            details = detail_fn(key, [t["id"] for t in board.get("tickets", [])], _post)
        except Exception as e:
            warnings.append(f"Linear not refreshed: detail: {str(e).replace(key, '***')[:160]}")
    else:
        warnings.append(f"Linear not refreshed: no usable key in the Keychain service {service!r}: {KEY_PROBLEM.get(service, 'not found')}")
    live = ("Linear not refreshed", "MR facts not refreshed")  # these describe this run only; a carried one would be stale
    board["feed_warnings"] = warnings + [w for w in (board.get("feed_warnings") or []) if not str(w).startswith(live)]
    with tempfile.TemporaryDirectory() as d:
        src, side = Path(d, "board.json"), Path(d, "collect.json")
        src.write_text(json.dumps(board))
        side.write_text(json.dumps(facts))
        cmd = [sys.executable, str(HERE / "render.py"), str(src), "--feed", str(Path(feed_path).expanduser()), "--collect", str(side)]
        r = render_run(cmd + (["--holds-cmd", holds_cmd] if holds_cmd else []), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("render.py failed: " + (r.stderr.strip() or r.stdout.strip())[-300:])
    fp = Path(feed_path).expanduser()
    feed = live_state.annotate_feed(json.loads(fp.read_text()), mr_states, ref_state, details)
    side_path = fp.with_name(fp.stem + ".actions.json")
    try:
        import render
        side = json.loads(side_path.read_text())
        for line in review_drafts.apply(feed, side.setdefault("actions", {}), str(fp.parent / "commands.jsonl"), live_state.mr_state, render.standard_actions,
                                         user=board.get("user") or "adomio"):
            print("info: " + line, file=sys.stderr)
        fd2, tmp2 = tempfile.mkstemp(prefix=side_path.name + ".", suffix=".tmp", dir=side_path.parent)
        with os.fdopen(fd2, "w") as f:
            json.dump(side, f, indent=1)
        os.replace(tmp2, side_path)
    except Exception as e:  # a failed lift leaves the feed as rendered
        warnings.append(f"Review drafts not lifted onto MR cards: {str(e)[:160]}")
        feed["warnings"] = list(feed.get("warnings") or []) + [warnings[-1]]
    # After the review drafts are on their cards: a card made for a report (obs !103) needs its approval too.
    try:
        rows = [(m["url"].rstrip("/"), "you" if m.get("role") == "author" else (m.get("author") or "")) for m in feed["mrs"] if m.get("state") == "opened"]  # own MRs are the user's to merge
        approvals.annotate_feed(feed, approvals_fn(rows, board.get("user") or "adomio"))
    except Exception as e:
        warnings.append(f"Approvals not refreshed: {str(e)[:160]}")
        feed["warnings"] = list(feed.get("warnings") or []) + [warnings[-1]]
    label_analysis_age(feed, board)
    fd, tmp = tempfile.mkstemp(prefix=fp.name + ".", suffix=".tmp", dir=fp.parent)
    with os.fdopen(fd, "w") as f:
        json.dump(feed, f, indent=1)
    os.replace(tmp, fp)
    return warnings


AGE_WARNING = "Card analysis is"


def label_analysis_age(feed, board, today=None):
    """Mark the board's own analysis text (MR next step, ticket finish step) with the board's date when it is older than today,
    and add one feed warning. Live facts stay as they are; verdicts are never rewritten."""
    try:
        board_day = date.fromisoformat(str(board.get("date") or ""))
    except ValueError:
        return feed
    days = ((today or date.today()) - board_day).days
    if days < 1:
        return feed
    stamp = f"Analysed {board_day.day} {board_day.strftime('%b')}: "
    from_board = {x["refs"][0][1] for x in board.get("mrs", []) if x.get("refs")} | {t.get("id") for t in board.get("tickets", [])}
    for m in feed.get("mrs", []):
        if m.get("ref") in from_board and m.get("next") and not str(m["next"]).startswith("Analysed "):
            m["next"] = stamp + m["next"]
    for t in feed.get("tickets", []):
        f = t.get("finish") or {}
        if t.get("identifier") in from_board and f.get("step") and not str(f["step"]).startswith("Analysed "):
            f["step"] = stamp + f["step"]
    warning = f"{AGE_WARNING} {days} day{'s' if days != 1 else ''} old (board {board_day.isoformat()})"
    feed["warnings"] = [w for w in (feed.get("warnings") or []) if not str(w).startswith(AGE_WARNING)] + [warning]
    return feed


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--board", default=os.environ.get("COMPANION_BOARD", "~/.config/linear-action-board/board.json"))
    ap.add_argument("--feed", default=os.environ.get("COMPANION_FEED", DEFAULT_FEED))
    ap.add_argument("--holds-cmd", default=os.environ.get("COMPANION_HOLDS_CMD"))
    ap.add_argument("--keychain-service", default=os.environ.get("COMPANION_LINEAR_KEYCHAIN_SERVICE", DEFAULT_SERVICE))
    ap.add_argument("--user", default=None)
    a = ap.parse_args(argv)
    try:
        warnings = refresh(a.board, a.feed, a.holds_cmd, a.keychain_service, a.user)
    except Exception as e:
        print(f"refresh failed, feed left as it was: {e}", file=sys.stderr)
        return 1
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
