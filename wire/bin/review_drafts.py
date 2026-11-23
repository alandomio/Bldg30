#!/usr/bin/env python3
"""Local producer addition (033): review comment drafts live on the MR card, never on a separate Decisions card.

A held decision "Post review comments on <MR>" names the review report (data/<task>/report.md). This reads that report's
"Comment drafts" section and puts every draft, in full, on the MR's card as mrs[].drafts, each with its placement
(file:line or general note), the finding it answers and, only when the report says so, a severity (required or
non-blocking). The MR row is created when the board has none. The decision card is dropped. A decision that asks to
post text but cannot be moved to a card (MR not open, report unreadable) keeps its card and gets the full draft text
appended to its context, so nobody decides blind.

Usage: imported by refresh.py (apply). Run directly for a dry run: review_drafts.py feed.json
"""
import json, os, re, subprocess, sys, time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = Path(os.environ["FM_HOME"]) / "data" if os.environ.get("FM_HOME") else HERE.parent.parent  # firstmate/data
RECENT_DAYS = 10
POST_TITLE = re.compile(r"^\s*post\b.*\b(comment|comments|review|reply|replies|draft|drafts|note|notes)\b", re.I)
REPORT_RE = re.compile(r"(/[^\s\"'<>]*?/report\.md)")
MR_URL_RE = re.compile(r"^(?:MR:\s*)?(https://\S+/-/merge_requests/(\d+))\s*$", re.M)
HEAD_RE = re.compile(r"^# Review:\s*(?P<what>[^\n,]+?)\s*,\s*(?P<title>[^\n]+)$", re.M)
AUTHOR_RE = re.compile(r"author ([^·\n]+?)\s*(?:·|$)", re.M)
VERDICT_RE = re.compile(r"^Verdict:\s*([^\n]+)", re.M)
SECTION = lambda name: re.compile(r"^## " + name + r"[^\n]*\n(.*?)(?=^## |\Z)", re.S | re.M)
DRAFT_BLOCK = re.compile(r"^placement:\s*(?P<place>[^\n]*?)\s*(?:\((?P<fid>F\d+)\))?\s*\n\s*```[a-z]*\n(?P<text>.*?)\n```", re.S | re.M)
FINDING_HEAD = re.compile(r"^### (F\d+)\.\s*([^\n]*)$", re.M)


def parse_report(path):
    """{url, iid, what, title, author, verdict, drafts:[{id, target, placement, finding, severity, text}]} or None."""
    try:
        report = Path(path).read_text()
    except OSError:
        return None
    mr = MR_URL_RE.search(report)
    sec = SECTION("Comment drafts").search(report)
    if not (mr and sec):
        return None
    head = HEAD_RE.search(report)
    author = AUTHOR_RE.search(report)
    verdict = VERDICT_RE.search(report)
    decided = " ".join(m.group(1) for m in (SECTION("Decisions for the human").search(report),) if m)
    consider = {f for f, rest in FINDING_HEAD.findall(report) if rest.lower().startswith("consider")}
    drafts = []
    for i, m in enumerate(DRAFT_BLOCK.finditer(sec.group(1))):
        text = m.group("text").strip("\n")
        if not text.strip():
            continue
        fid = m.group("fid") or ""
        place = m.group("place").strip()
        general = place.lower().startswith("general")
        loc = "" if general else re.sub(r"^inline\s+", "", place).split(" @")[0].strip()
        if fid in consider or re.match(r"\s*non-?blocking\b", text, re.I):
            severity = "non-blocking"
        elif fid and re.search(r"\b" + fid + r"\b", decided):
            severity = "required"
        else:
            severity = ""
        drafts.append({"id": fid.lower() or f"d{i}", "target": loc or "General note", "placement": place, "finding": fid,
                       "severity": severity, "text": text})
    if not drafts:
        return None
    return {"url": mr.group(1), "iid": mr.group(2), "what": head.group("what") if head else "", "title": head.group("title").strip() if head else "",
            "author": author.group(1).strip() if author else "", "verdict": verdict.group(1).strip() if verdict else "", "drafts": drafts,
            "task": Path(path).parent.name, "written": Path(path).stat().st_mtime}


def posted_ids(ledger_path):
    """{(target, action_id)} that a ShipDeck click queued and firstmate marked done."""
    queued, done = {}, set()
    try:
        lines = Path(ledger_path).expanduser().read_text().splitlines()
    except OSError:
        return set()
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("action_id"):
            queued[r["id"]] = (r.get("target"), r["action_id"])
        if r.get("state") == "done":
            done.add(r.get("id"))
    return {queued[i] for i in done if i in queued}


def mr_notes(url, run=subprocess.run):
    """The MR's notes (inline and general) as {body, author, at (epoch)}, or None when GitLab could not be read."""
    m = re.match(r"https://[^/]+/(.+?)/-/merge_requests/(\d+)", url)
    if not m:
        return None
    r = run(["glab", "api", "--paginate", f"projects/{m.group(1).replace('/', '%2F')}/merge_requests/{m.group(2)}/notes?per_page=100"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        text = "".join(c for c in r.stdout if c >= " " or c in "\n\t")
        return [{"body": n.get("body", ""), "author": (n.get("author") or {}).get("username", ""), "at": _epoch(n.get("created_at"))}
                for chunk in re.split(r"(?<=\])\s*(?=\[)", text) for n in json.loads(chunk) if isinstance(n, dict) and not n.get("system")]
    except ValueError:
        return None


def _epoch(iso):
    try:
        return datetime.fromisoformat(str(iso).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0


def user_replied_after(rep, notes, user):
    """True when the user wrote a note on the MR after the report was written: the user chose what to post, so its drafts are done."""
    since = rep.get("written") or 0
    return bool(user and since) and any(isinstance(n, dict) and n.get("author") == user and n.get("at", 0) > since for n in notes)


def is_posted(draft, bodies):
    """A draft counts as posted when its first line, whitespace squeezed, is inside an existing note."""
    key = " ".join(draft["text"].split("\n", 1)[0].split())[:70]
    return bool(key) and any(key in " ".join(b.split()) for b in bodies)


def recent_reports(data=DATA, days=RECENT_DAYS, now=None):
    """Every report.md among data/rv-*/ folders touched in the last `days` days that has comment drafts, newest first.
    Several workers can review the same MR; each report keeps its own drafts (a worker is only swept when its own are posted).
    A draft id already used by a newer report of the same MR gets the task name in front, and a draft with the same text is dropped."""
    found = []
    cutoff = (now or time.time()) - days * 86400
    for path in Path(data).glob("rv-*/report.md"):
        mtime = path.stat().st_mtime
        if mtime < cutoff:
            continue
        rep = parse_report(path)
        if rep:
            found.append((mtime, rep))
    found.sort(key=lambda x: -x[0])
    ids, texts, out = {}, {}, []
    for _, rep in found:
        used, seen = ids.setdefault(rep["url"], set()), texts.setdefault(rep["url"], set())
        drafts = []
        for d in rep["drafts"]:
            key = " ".join(d["text"].split())
            if key in seen:
                continue
            seen.add(key)
            if d["id"] in used:
                d = {**d, "id": f"{rep.get('task') or 'r'}-{d['id']}"}
            used.add(d["id"])
            drafts.append(d)
        if drafts:
            out.append({**rep, "drafts": drafts})
    return out


def short_by_project(feed):
    """{project path: short name} learned from the feed's own MR refs ('obs !42' at .../devops/observability/...)."""
    out = {}
    for mr in feed.get("mrs", []):
        m = re.match(r"https://[^/]+/(.+?)/-/merge_requests/", mr.get("url", ""))
        r = re.match(r"([\w/-]+)\s?!\d+", mr.get("ref", ""))
        if m and r:
            out[m.group(1)] = r.group(1)
    return out


def post_prompt(ref, url, draft, hold_id):
    where = "a general MR note" if draft["placement"].lower().startswith("general") else f"an inline discussion at {draft['placement']}"
    return (f"Post review comment {draft['finding'] or draft['id']} on {ref} ({url}) as {where}. The exact text is the draft text of this click; post it "
            "unchanged, nothing else. Before posting, check live that the MR is still open and, for an inline comment, that the head SHA in the placement "
            "is still the MR head (if not, post nothing and say so). Use glab api for the discussion (position needs the diff refs of the head). "
            f"Report the comment link. When no unposted draft of {ref} is left, release the hold {hold_id} with fm-captain-hold.sh answer {hold_id} "
            "--decision-file <note: comments posted> --release.")


def build_row(feed, rep, ref, hold_id, sidecar, standard_actions):
    rid = "row-mr-" + re.sub(r"[^a-z0-9]+", "-", ref.lower()).strip("-")
    actions = []
    for d in rep["drafts"]:
        aid = f"{rid}.comment-{d['id']}"
        actions.append({"id": aid, "label": f"Post {d['target']}", "outward": True})
        sidecar[aid] = {"label": f"Post {d['target']}", "target": ref, "outward": True, "prompt": post_prompt(ref, rep["url"], d, hold_id)}
    wtf, never = standard_actions({"refs": [[rep["url"], ref, rep["title"]]], "id": ref, "task": hold_id}, ref)
    for a in (wtf, never):
        aid = f"{rid}.{re.sub(r'[^a-z0-9]+', '-', a['label'].lower()).strip('-')}"
        actions.append({"id": aid, "label": a["label"], "outward": False})
        sidecar[aid] = {"label": a["label"], "target": ref, "outward": False, "prompt": a["prompt"]}
    n = len(rep["drafts"])
    return {"ref": ref, "url": rep["url"], "title": rep["title"], "role": "reviewer", "verdict": "notyet",
            "label": f"{n} review comment{'s' if n != 1 else ''} to post", "next_owner": "You", "pipeline": None, "open_threads": None,
            "drafts": [{"id": d["id"], "target": d["target"], "target_url": rep["url"], "text": d["text"], "placement": d["placement"],
                        "finding": d["finding"], **({"severity": d["severity"]} if d["severity"] else {}),
                        **({"source": rep["task"]} if rep.get("task") else {})} for d in rep["drafts"]],
            "actions": actions, "author": rep["author"], "headline": f"Post the review comments on {ref}",
            "blocker": rep["verdict"], "next": "Read each draft, then post, edit or discard it.", "ticket": "", "updated_at": "", "state": "opened"}


def inline_text(decision, rep):
    """The decision's context plus every draft in full, once."""
    ctx = decision.get("full_context") or decision.get("why_now") or ""
    if "Full text of the drafts:" in ctx:
        return ctx
    body = "\n\n".join(f"[{d['target']}{' · ' + d['severity'] if d['severity'] else ''}]\n{d['text']}" for d in rep["drafts"])
    return ctx + "\n\nFull text of the drafts:\n\n" + body


def place(feed, rep, ref, hold_id, sidecar, standard_actions):
    """Put the report's drafts on the MR's card, creating the card when the board has none."""
    row = next((x for x in feed["mrs"] if x["url"].rstrip("/") == rep["url"].rstrip("/")), None)
    fresh = build_row(feed, rep, ref, hold_id, sidecar, standard_actions)
    if row is None:
        feed["mrs"].insert(0, fresh)
        return
    have = {d["id"] for d in row["drafts"]}
    row["drafts"] += [d for d in fresh["drafts"] if d["id"] not in have]
    ids = {d["id"] for d in fresh["drafts"]}
    row["actions"] = [a for a in fresh["actions"] if ".comment-" in a["id"]] + [a for a in row["actions"] if not any(a["id"].endswith(".comment-" + i) for i in ids)]


def apply(feed, sidecar, ledger_path, state_fn, standard_actions, short=None, notes_fn=mr_notes, reports=None, user="adomio"):
    """Review comments go on MR cards. Two sources: held decisions "Post review comments on ..." that name a report (the
    decision card is dropped), and recent review reports of open MRs whose drafts are not in a GitLab note yet.
    Returns info lines; feed and sidecar are changed in place."""
    info, keep, placed = [], [], set()
    shorts = short or short_by_project(feed)
    done = posted_ids(ledger_path)

    def ref_of(rep):
        project = re.match(r"https://[^/]+/(.+?)/-/merge_requests/", rep["url"]).group(1)
        return f"{shorts.get(project) or project.split('/')[-1]} !{rep['iid']}"

    def unposted(rep):
        """The report with only the drafts GitLab does not hold yet, or None when GitLab cannot be read or nothing is left."""
        notes = notes_fn(rep["url"])
        if notes is None:
            info.append(f"{rep['url']}: notes not readable, drafts not offered")
            return None
        if user_replied_after(rep, notes, user):
            info.append(f"{rep['url']}: {user} wrote a note after report {rep.get('task')}, its drafts not offered")
            return None
        bodies = [n["body"] if isinstance(n, dict) else n for n in notes]
        left = [d for d in rep["drafts"] if not is_posted(d, bodies)]
        return {**rep, "drafts": left} if left else None

    for dec in feed.get("decisions", []):
        m = REPORT_RE.search(dec.get("full_context") or "") if POST_TITLE.match(dec.get("title") or "") else None
        rep = parse_report(m.group(1)) if m else None
        if not rep:
            keep.append(dec)
            continue
        ref = ref_of(rep)
        if state_fn(rep["url"]) in ("merged", "closed"):
            info.append(f"{dec['id']}: {ref} is merged or closed, nothing left to post; decision left off the feed")
            continue
        if state_fn(rep["url"]) != "opened":
            dec["full_context"] = inline_text(dec, rep)
            keep.append(dec)
            info.append(f"{dec['id']}: {ref} state unknown, decision kept with the draft text inline")
            continue
        left = unposted(rep)
        if left:
            place(feed, left, ref, dec["id"], sidecar, standard_actions)
            placed.add((rep["url"], rep.get("task")))
            info.append(f"{dec['id']}: {len(left['drafts'])} drafts moved onto the card of {ref}")
    for rep in (recent_reports() if reports is None else reports):
        if (rep["url"], rep.get("task")) in placed or state_fn(rep["url"]) != "opened":
            continue
        left = unposted(rep)
        if left:
            place(feed, left, ref_of(rep), "none", sidecar, standard_actions)
            placed.add((rep["url"], rep.get("task")))
            info.append(f"{ref_of(rep)}: {len(left['drafts'])} review drafts from a recent report put on the card")
    # A draft that a click already posted is not offered again.
    for mr in feed["mrs"]:
        for a in [a for a in mr["actions"] if ".comment-" in a["id"] and (mr["ref"], a["id"]) in done]:
            did = a["id"].split(".comment-", 1)[1]
            mr["drafts"] = [d for d in mr["drafts"] if d["id"] != did]
            mr["actions"] = [x for x in mr["actions"] if x["id"] != a["id"]]
    feed["decisions"] = keep
    return info


if __name__ == "__main__":
    import render
    feed = json.load(open(sys.argv[1]))
    for line in apply(feed, {}, "~/Library/Application Support/ModelDeck/companion/commands.jsonl", lambda u: "opened", render.standard_actions, notes_fn=lambda u: []):
        print(line)
    print(json.dumps([m for m in feed["mrs"] if m["ref"].endswith("!101")], indent=1)[:3000])
