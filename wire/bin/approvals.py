#!/usr/bin/env python3
"""Live GitLab approvals for the companion feed (local producer, 034).

Per open MR: who approved, approvals left, whether the user approved. For an MR the user reviews and approved, the card
moves to "Waiting on others" when the approval is at the current head (no commit after it) and no unresolved thread waits
on the user. A thread waits on the user when its last human note is by someone who is neither the user nor the MR author
and the thread holds a note by the user or mentions @user. The author's own unanswered notes never count.
"""
import json, re, subprocess
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

URL_RE = re.compile(r"^https://[^/]+/(.+?)/-/merge_requests/(\d+)")


def _get(url, path, run, paginate=False):
    m = URL_RE.match(url or "")
    if not m:
        return None
    cmd = ["glab", "api"] + (["--paginate"] if paginate else []) + [f"projects/{m.group(1).replace('/', '%2F')}/merge_requests/{m.group(2)}{path}"]
    r = run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return None
    text = "".join(c for c in r.stdout if c >= " " or c in "\n\t")
    try:
        out = []
        for chunk in re.split(r"(?<=\])\s*(?=\[)", text) if paginate else [text]:
            v = json.loads(chunk)
            out += v if isinstance(v, list) else [v]
        return out
    except ValueError:
        return None


def _t(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def waits_on_user(discussions, user, author):
    """True when an unresolved thread waits on the user (see module doc)."""
    me, au = user.lower(), (author or "").lower()
    for d in discussions:
        notes = [n for n in d.get("notes", []) if not n.get("system")]
        if not notes or not any(n.get("resolvable") for n in notes) or all(n.get("resolved") for n in notes if n.get("resolvable")):
            continue
        last = notes[-1]["author"]["username"].lower()
        if last in (me, au):
            continue
        if any(n["author"]["username"].lower() == me or re.search(r"@" + re.escape(me) + r"\b", n.get("body", ""), re.I) for n in notes):
            return True
    return False


def username(author):
    """'Riley Kim (rkim)' -> 'rkim'; a bare username stays."""
    m = re.search(r"\(([^)\s]+)\)\s*$", author or "")
    return m.group(1) if m else (author or "")


def approval(url, user, author, run=subprocess.run):
    """{approved_by, approved_by_me, approvals_left, at_head, waiting_on} or None when GitLab could not be read.
    waiting_on is the author's username when the card belongs in Waiting on others, else ''. That is when nothing is owed by the user
    (no thread waits on them) and either they approved at the current head, or the MR has an approval and none left (038, 039)."""
    a = _get(url, "/approvals", run)
    if not a:
        return None
    a = a[0]
    author = username(author)
    names = [x["user"]["username"] for x in a.get("approved_by", [])]
    me = user.lower() in (n.lower() for n in names)
    left = a.get("approvals_left")
    out = {"approved_by": [n for n in names if n.lower() != user.lower()], "approved_by_me": me, "approvals_left": left, "at_head": None, "waiting_on": ""}
    commits = _get(url, "/commits?per_page=1", run)
    if commits and commits[0].get("id"):
        out["head_sha"] = commits[0]["id"]  # lets the app hide a dismissed MR only until a new commit arrives (038)
    if not author or author.lower() in (user.lower(), "you", "me") or not names:  # an MR of the user's own is theirs to merge
        return out
    done = left == 0
    if not me and not done:
        return out
    threads = _get(url, "/discussions?per_page=100", run, True)
    if threads is None or waits_on_user(threads, user, author):
        return out
    if me:
        notes = _get(url, "/notes?per_page=100&sort=desc", run, True)
        if notes is not None and commits:
            mine = [n["created_at"] for n in notes if n.get("system") and n["author"]["username"].lower() == user.lower() and n.get("body", "").startswith("approved this merge request")]
            if mine:
                out["at_head"] = _t(max(mine, key=_t)) >= _t(commits[0]["created_at"])
    if done or out["at_head"]:
        out["waiting_on"] = author
    return out


def fetch(rows, user, run=subprocess.run):
    """{url: approval dict} for [(url, author)] rows."""
    with ThreadPoolExecutor(6) as ex:
        return {u: r for (u, _), r in zip(rows, ex.map(lambda x: approval(x[0], user, x[1], run), rows)) if r}


def approved_label(a, who):
    """'Approved by jdoe · 0 left · waiting on rkim to merge' from live facts; 'you' only when the user approved."""
    names = (["you"] if a.get("approved_by_me") else []) + list(a.get("approved_by") or [])
    left = a.get("approvals_left")
    return f"Approved by {', '.join(names)}" + (f" · {left} left" if left is not None else "") + f" · waiting on {who} to merge"


def annotate_feed(feed, by_url):
    """mrs[].approval everywhere it is known; a waiting row becomes a plain 'waiting on <author> to merge' row."""
    for mr in feed.get("mrs", []):
        a = by_url.get(mr["url"].rstrip("/"))
        if not a:
            continue
        mr["approval"] = {k: v for k, v in a.items() if k != "waiting_on" and v is not None}
        if a["waiting_on"]:
            who = a["waiting_on"]
            mr["waiting_on"] = who
            mr.update({"verdict": "hold", "label": approved_label(a, who), "next_owner": who,
                       "headline": f"Waiting on {who} to merge", "blocker": "", "next": f"Waiting on {who} to merge."})
    return feed
