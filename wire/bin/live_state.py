#!/usr/bin/env python3
"""Live GitLab state and Linear detail for the companion feed (local producer; not part of ai-skills !57).

A board row for an MR that GitLab says is merged or closed must not reach the feed: its drafts and buttons would act on a finished MR.
`states()` asks GitLab once per MR per refresh; a failed lookup returns None and the row stays (never guessed).
"""
import json, re, subprocess
from concurrent.futures import ThreadPoolExecutor

FINISHED = {"merged", "closed"}
URL_RE = re.compile(r"^https://[^/]+/(.+?)/-/merge_requests/(\d+)")


def mr_state(url, run=subprocess.run):
    """'opened' | 'merged' | 'closed' | 'locked', or None when the lookup failed."""
    m = URL_RE.match(url or "")
    if not m:
        return None
    r = run(["glab", "api", f"projects/{m.group(1).replace('/', '%2F')}/merge_requests/{m.group(2)}"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        state = json.loads("".join(c for c in r.stdout if c >= " " or c in "\n\t")).get("state")
    except ValueError:
        return None
    return state if isinstance(state, str) and state else None


def states(urls, lookup=mr_state):
    """{url: state or None}"""
    urls = sorted(set(urls))
    with ThreadPoolExecutor(8) as ex:
        return dict(zip(urls, ex.map(lookup, urls)))


def row_url(row):
    refs = row.get("refs") or []
    return refs[0][0].rstrip("/") if refs and refs[0] else ""


def prune_board(board, open_urls, lookup=mr_state):
    """Drop board MR rows whose MR is merged or closed on GitLab. A row marked "merged": true (the user's own MR that still waits for
    its apply/release) stays: that is the 'Merged, apply not confirmed' reminder. Returns (dropped refs, {url: state}, [warnings])."""
    rows = board.get("mrs", [])
    check = [row_url(x) for x in rows if row_url(x) and row_url(x) not in open_urls]
    found = states(check, lookup)
    keep, dropped, warnings = [], [], []
    for x in rows:
        url = row_url(x)
        state = "opened" if url in open_urls else found.get(url)
        if state in FINISHED and not x.get("merged"):
            dropped.append(x["refs"][0][1]); continue
        if url and url not in open_urls and state is None:
            warnings.append(f"MR state not read: {x['refs'][0][1]}")
        keep.append(x)
    board["mrs"] = keep
    finish_tickets(board, {x["refs"][0][1]: (x.get("ticket"), found.get(row_url(x))) for x in rows if x["refs"][0][1] in dropped})
    states_all = {url: "opened" for url in open_urls}
    states_all.update({u: s for u, s in found.items() if s})
    return dropped, states_all, warnings


def finish_tickets(board, gone):
    """A ticket whose only MR just merged or closed would keep no button: give it a real verify-and-close step instead.
    gone: {mr ref: (ticket id or None, 'merged' | 'closed')}."""
    for x in board.get("tickets", []) + board.get("decisions", []) + board.get("mrs", []):
        src = x.get("decision_ref")
        if src in gone:  # the decision lived on a finished MR row, which is gone now
            x.pop("decision_ref")
            x["label"] = f"{src} {gone[src][1]}: re-check"
    for t in board.get("tickets", []):
        refs = [r for r, (tid, _) in gone.items() if tid == t.get("id") or r == t.get("mr")]
        if not refs or t.get("actions") or any(t.get("mr") == x["refs"][0][1] for x in board.get("mrs", [])):
            continue
        what = ", ".join(f"{r} {gone[r][1]}" for r in refs)
        t["verdict"], t["owner"], t["label"] = "close", "You", "MR merged: verify, then close"
        t["next"] = f"{what}. <b>Next:</b> check the apply or release and the acceptance criteria, then close {t['id']}."
        t["finish"] = {"step": f"Verify {what} and close {t['id']}", "owner": "You"}
        t["actions"] = [{"label": "Verify and close", "outward": True, "prompt":
                         f"{t['id']}: {what}. Check live evidence for each acceptance criterion (apply or release state, "
                         "monitors, staging proof). If all are met, show the evidence and set the ticket Done after the user confirms; "
                         "if not, write the gap on this row with board_state.py. Never post a Linear comment without approval of its exact text."}]


def annotate_feed(feed, states_by_url, ref_state, details):
    """Set mrs[].state where it is known and tickets[].detail where Linear gave it; a kept 'merged, apply pending' row gets no state."""
    for mr in feed.get("mrs", []):
        state = states_by_url.get(mr["url"].rstrip("/"))
        if state == "opened":
            mr["state"] = state
    for t in feed.get("tickets", []):
        d = details.get(t["identifier"])
        if not d:
            continue
        d = dict(d)
        d["mrs"] = [{"ref": ref, "state": ref_state.get(ref)} for ref in t.get("linked_mrs", [])]
        d["mrs"] = [{k: v for k, v in e.items() if v} for e in d["mrs"]]
        t["detail"] = {k: v for k, v in d.items() if v not in (None, "", [])}
    return feed


CHECK_RE = re.compile(r"^\s*[-*]\s*\[([ xX])\]\s*(.+?)\s*$")


def parse_acceptance(description):
    return [{"text": m.group(2)[:200], "done": m.group(1).lower() == "x"} for m in map(CHECK_RE.match, (description or "").splitlines()) if m][:12]


def parse_summary(description):
    """The first paragraph with real prose (a lone heading such as 'Business Value:' is skipped), at most 300 characters."""
    for para in re.split(r"\n\s*\n", (description or "").strip()):
        text = " ".join(l.strip() for l in para.splitlines() if not CHECK_RE.match(l) and not l.lstrip().startswith("#")).strip()
        if len(text) >= 25 and not text.endswith(":"):
            return text[:300]
    return ""


def linear_detail(issue):
    """The feed's tickets[].detail fields (without mrs) from one Linear issue node."""
    comments = sorted(((issue.get("comments") or {}).get("nodes") or []), key=lambda c: c.get("createdAt") or "")[-5:]
    return {
        "assignee": ((issue.get("assignee") or {}).get("name") or ""),
        "priority": issue.get("priorityLabel") or "",
        "labels": [n["name"] for n in ((issue.get("labels") or {}).get("nodes") or []) if n.get("name")],
        "summary": parse_summary(issue.get("description")),
        "acceptance": parse_acceptance(issue.get("description")),
        "comments": [{"author": (c.get("user") or {}).get("name") or "", "at": (c.get("createdAt") or "")[:16].replace("T", " "), "text": (c.get("body") or "")[:300]} for c in reversed(comments)],
    }


def fetch_details(key, identifiers, post):
    """{identifier: detail dict}; one GraphQL call. Errors never carry the key."""
    ids = sorted({i for i in identifiers if re.match(r"^[A-Za-z][A-Za-z0-9]*-\d+$", i)})
    if not ids:
        return {}
    fields = "identifier description priorityLabel assignee { name } labels { nodes { name } } comments(last: 5) { nodes { createdAt body user { name } } }"
    query = "query{" + " ".join(f'i{n}: issue(id: "{i}") {{ {fields} }}' for n, i in enumerate(ids)) + "}"
    data = post("https://api.linear.app/graphql", {"query": query}, {"Authorization": key, "Content-Type": "application/json"})
    if data.get("errors") and not data.get("data"):
        raise RuntimeError("Linear detail: " + "; ".join(str(e.get("message", ""))[:80] for e in data["errors"][:3]))
    return {v["identifier"]: linear_detail(v) for v in (data.get("data") or {}).values() if v}
