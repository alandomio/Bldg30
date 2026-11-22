#!/usr/bin/env python3
"""Render the Linear Action Board HTML from a board JSON file.

board.json:
{
  "date": "2026-10-02",
  "tickets_lede": "...", "mrs_lede": "...",
  "tickets": [{"id": "IN-2600", "what": "...", "status": "In Review",
               "verdict": "close|notyet|blocked|hold", "label": "Not yet",
               "next": "<html allowed>", "owner": "You"}],
  "mrs": [{"refs": [["url", "pi !1834", "title?"], ...], "what": "...", "author": "Sam",
           "verdict": "...", "label": "...", "next": "<html>", "owner": "..."}],
  "chips": {"Merged since last board": 3, ...}  # optional plain-count chips; a row's "chips": ["Label"] tags it for a filter chip
}
Any ticket or MR row may carry "draft_file": "<path>" (or "draft": "<text>"): the pending
comment or reply draft, shown behind a "Show draft" toggle so it can be read without opening
anything. Any ticket or MR row may also carry "actions": [{"label": "Post reply", "prompt": "<exact
instruction for the agent>", "outward": true}]. With --lavish the rows get buttons that
queue that prompt to the agent session (window.lavish.queuePrompt); outward actions ask
for a confirm click showing the prompt. Without --lavish actions are ignored (read-only page).
Every row gets a stable id: row-t-<ticket id> (row-t-in-2600) or row-mr-<first MR ref> (row-mr-pi-1903).
Duplicate ids abort the render. A row may carry "progress": {"done": [{"text": "Approved", "at": "10:42"}],
"pending": "Merge when CI is green", "owner": "You"}, shown at the top of its next-action cell.
With --lavish the page polls board-state.json next to it every 5 s, patching only listed rows:
{"rows": {"row-mr-pi-1903": {"verdict": "close", "label": "Approved", "next": "<b>Next:</b> merge",
  "done_actions": ["Approve"], "progress": {...as above...}}}}
(all keys optional; "next" allows only a, b, strong, em, i, code, br; progress is plain text)
Every row gets "Add context", "Wait, what?" and "Nevermind" buttons with --lavish (never outward), and every hold row owned
by someone else an outward "Nudge <owner>" button. Optional row fields: "note_draft": {"kind", "target", "text"}
(Post/Edit/Discard box, --lavish only), "drafts": [{"id", "target", "target_url", "text", "posted_at"?}] (one editable box per drafted message, each posted separately; a state patch {"drafts": [{"id", "posted_at"}]} marks one posted), "decided": {"option", "at"} (a handled decision: the option cards become a one-line record, and a standalone
decision row is dropped), "explained": {"text", "at"} (the plain-English re-explanation written back by "Wait, what?": the button turns yellow
when sent and green once it appears), "context_saved": true (or "cards": [...]) turns "Add context" green, "cards": [{"slug", "title", "url"?}] (linked Brain cards), and
"updated" (YYYY-MM-DD). Top level: "abandoned": [{"ref", "date"}] (rows whose board task is abandoned are
dropped unless "updated" is later) and "sync_error": "<why>" (banner). --tasks f.json writes one {key, status,
title} per row for the board tasks.
Every row needs a real action besides Nevermind: an explicit action or the default Nudge on a hold row
owned by someone else ("You"/"Me"/"User" or board.json "user" do not count). Otherwise render aborts and
names the row; finished rows are dropped from board.json, not shown.
A row with "progress.pending" (one step left) must not carry a generic label ("Not yet", "Waiting"...).
A decision that blocks a ticket or MR goes ON that row ("decision" key; the row sorts into Decide and its
options are its actions). Only decisions with no ticket or MR (Brain writes, process calls) go in a top-level
"decisions" row {id, what, owner, decision}, also loadable with --decisions f.json; one that names a ticket/MR
("ticket"/"mr" key) or reuses a row's id aborts. A ticket and MR blocked by the same decision: the MR row holds it and renders it once; the ticket row says "decision_ref": "<MR ref>" and shows only a "Decision on <ref>" link line.
A row may carry "decision": {"question", "options": [{"label", "consequence", "prompt", "recommended", "outward"?}]}:
1 to 4 options, one button each, exactly one recommended when several; options count as real actions.
An "outward": true option posts text: the row needs "draft"/"draft_file", shown inline on the card; no draft aborts.
Top-level "buddy_tasks": [{"key", "what", "owner", "next", ...}] shows the buddy's open non-board tasks as rows
(ref buddy-<key>, never written back by --tasks; Nevermind abandons that buddy task; board-* keys are skipped).
Ticket rows show "title" (or "what") after the id; an MR row shows its title after the ref (a single MR: "title"
or "what"; a group: each ref may be [url, label, title] and gets its own line). A ticket shows one status pill (To Do white with
a grey border, In Progress yellow, In Review orange, Staging teal, Done blue; "state_colors": {"Staging": "#2bb5a0"}
overrides a #rrggbb; text is dark or white by contrast) and the step left to Done as plain text.
An MR row's "merge_state" (conflicts, pipeline, approved, open_threads...) adds Merge on the user's own MR when all clear
and open_threads is 0, or Resolve and merge when threads are open (final feedback check, then resolve and merge).
An MR row with "merged": true (the user's own, in a project listed in ships.json) renders as "Merged, apply not confirmed"
or "Merged, release not confirmed" with a Mark applied / Mark released button; optional "ticket": "IN-2600" and
"ticket_status": a Done or Canceled ticket drops the row and --tasks marks its task done.
Facts to buttons (mr_steps.py): top-level "collect": "<collect_mrs.py --format json output>" (or --collect f.json) gives each MR
row, matched by its URL, a merge_state derived from the facts (unless the row carries one) and a first button that performs the step
its state names: Rebase it, Rework it, Fix the pipeline, Fix the threads (own MRs), Start review (MRs the user reviews). Without
facts the row's "step" (rebase|rework|fix_pipeline|fix_threads|review|none) or its label decides. A top-level "review_reports"
folder template ({ref} pi-1929, {short} pi, {iid} 1929; or a row's "review": folder) lifts the review's comment draft onto the
row as drafts boxes, plus Approve when its Verdict opens with "Safe to approve".
A ticket row takes the step and merge buttons of its own MR rows (the ticket's "mr" ref or list, the MR row's "ticket", or the
ticket id in the MR's title); several MRs get their ref on each label.
No merge_state is derived (and a hand-written one adds no button) for an MR row with verdict hold or blocked, a label saying it is not
merge-ready, or "depends_on": ["ts !6260"] naming an MR not merged (or a target branch other than main).
--tasks also writes each ticket and MR task's "delivery" line (see delivery_line); a row's optional "stage"
(review|merged|applied|done) overrides the derived stage.
--feed feed.json also writes the companion-feed.v1 file (feed.py; out.html may then be left out) plus feed.actions.json
(action id to prompt, for firstmate's click handling; --actions-out moves it). --holds-cmd "<command>" (else $COMPANION_HOLDS_CMD)
is firstmate's read command for tasks held for the captain; it prints JSON decisions or a tasks-axi list.
Usage: render.py board.json [out.html] [--lavish] [--tasks tasks.json] [--decisions f.json] [--collect collect.json]
       [--feed feed.json] [--holds-cmd "<cmd>"] [--actions-out actions.json]
"""
import html, json, os, re, sys
from pathlib import Path

import feed
import org
import mr_steps

TEMPLATE = Path(__file__).with_name("template.html")
VERDICTS = {"close", "notyet", "blocked", "hold"}


def link(url, text):
    return f'<a href="{html.escape(url)}" target="_blank" rel="noopener">{html.escape(text)}</a>'


def ref_lines(refs, fallback_title="", per_line=3):
    """MR refs [url, label, title?]. One MR: ref and title. Titled group: one MR per line with its title.
    Untitled group: at most per_line refs per line, so a many-MR row does not widen its column."""
    def ttl(r):
        t = r[2] if len(r) > 2 else (fallback_title if len(refs) == 1 else "")
        return f' <span class="ttl">{html.escape(t)}</span>' if t else ""
    if len(refs) == 1 or any(len(r) > 2 for r in refs):
        return "<br>".join(link(r[0], r[1]) + ttl(r) for r in refs)
    links = [link(u, t) for u, t, *_ in refs]
    return "<br>".join(" · ".join(links[i:i + per_line]) for i in range(0, len(links), per_line))


def pill(v, label):
    if v not in VERDICTS:
        raise ValueError(f"unknown verdict {v!r}")
    return f'<span class="pill {v}">{html.escape(label)}</span>'


LAVISH = False


PROJECTS = org.PROJECTS  # short name -> GitLab path under the group (local org config, see org.py)
REF = re.compile(r"\b(" + ("|".join(sorted(map(re.escape, PROJECTS), key=len, reverse=True)) or r"(?!x)x")
                 + r")\s?!(\d+)|\b((?:" + ("|".join(map(re.escape, org.TICKET_PREFIXES)) or r"(?!x)x") + r")-\d+)\b")


def autolink(fragment):
    """Link MR refs (pi !1904) and ticket ids (IN-2600) in row text, outside tags and links."""
    out, inside_a = [], False
    for part in re.split(r"(<[^>]+>)", fragment):
        if part.startswith("<"):
            low = part.lower()
            inside_a = True if low.startswith("<a ") else False if low.startswith("</a") else inside_a
            out.append(part)
        elif inside_a:
            out.append(part)
        else:
            def sub(m):
                if m.group(3):
                    return link(org.LINEAR_ISSUE_BASE + m.group(3), m.group(3))
                url = f"{org.GITLAB_BASE}{PROJECTS[m.group(1)]}/-/merge_requests/{m.group(2)}"
                return f'<a href="{url}" target="_blank" rel="noopener">{m.group(0)}</a>'
            out.append(REF.sub(sub, part))
    return "".join(out)


def draft_text(x):
    """The row's draft (inline text or a readable draft_file), or None."""
    text = x.get("draft")
    if not text and x.get("draft_file"):
        try:
            text = Path(x["draft_file"]).expanduser().read_text()
        except OSError:
            return None
    return text or None


def posts_text(x):
    """True while the row has a decision with an outward (posting) option that has not landed yet."""
    return bool(not x.get("decided") and any(o.get("outward") for o in (x.get("decision") or {}).get("options", [])))


def draft(x):
    if posts_text(x):  # shown inline on the decision card instead, never behind a toggle
        return ""
    text = draft_text(x)
    if text is None and x.get("draft_file"):
        text = f"(draft file not found: {x['draft_file']})"
    if not text:
        return ""
    return ('<details class="draft"><summary>Show draft</summary>'
            f'<pre style="white-space:pre-wrap;font-size:12px;margin:6px 0 0">{html.escape(text)}</pre></details>')


SELF = {"you", "me", "user"}


def owner_parts(owner):
    return [p for p in re.split(r"\s*(?:/|,|&|\+|\band\b)\s*", owner.lower()) if p]


def has_self(owner, user=""):
    """True when the user is among the owners ('You', 'You / reviewers', 'Riley / You')."""
    return bool(set(owner_parts(owner)) & (SELF | ({user.lower()} if user else set())))


def waiting_on_others(x, user=""):
    """Nobody owes the user anything: other owners only, or a hold on a row owned by the user alone."""
    owner = x.get("owner", "")
    if owner and not has_self(owner, user):
        return True
    return x.get("verdict") == "hold" and len(owner_parts(owner)) <= 1


KEY_RE = re.compile(r"[a-z0-9][a-z0-9_-]{1,63}")


def valid_key(key):
    if not KEY_RE.fullmatch(key):
        raise ValueError(f"bad task key {key!r}: Brain keys must match [a-z0-9][a-z0-9_-]{{1,63}}")
    return key


def task_key(x):
    """Brain task key, always prefixed by kind so it never depends on the other rows: board-t-<ticket id>
    (board-t-in-2357), board-mr-<first MR ref> (board-mr-pi-1903), board-d-<decision id>."""
    if "_task_key" in x:
        return x["_task_key"]
    kind, ref = ("mr", x["refs"][0][1]) if "refs" in x else (x.get("_kind", "t"), x["id"])
    prefix = f"board-{kind}-"
    core = re.sub(r"[^a-z0-9_-]+", "-", ref.lower()).strip("-")[:64 - len(prefix)].strip("-")
    return valid_key(prefix + core) if core else valid_key("!" + ref)


def task_status(x, user=""):
    """in_progress while the user owes the next step (a mergeable MR always), blocked while others do (done/abandoned are set by the agent)."""
    return "blocked" if waiting_on_others(x, user) and not x.get("_mergeable") else "in_progress"


STAGES_DELIVERY = ("review", "merged", "applied", "done")
DELIVERY_RE = re.compile(r"^delivery: stage=(review|merged|applied|done) \| next=([^|\n]+) \| owner=([^|\n]+) "
                         r"\| changed=(\d{4}-\d{2}-\d{2})$", re.M)


def delivery_line(stage, step, owner, changed):
    """The fixed first line of a board-t-*/board-mr-* task's content, parsed and written by other tools too:
    delivery: stage=<review|merged|applied|done> | next=<step> | owner=<owner> | changed=<YYYY-MM-DD>"""
    if stage not in STAGES_DELIVERY or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", changed or ""):
        raise ValueError(f"bad delivery line: stage {stage!r} (one of {', '.join(STAGES_DELIVERY)}), changed {changed!r} (YYYY-MM-DD)")
    def clean(v):
        v = html.unescape(re.sub(r"<[^>]+>", "", str(v or ""))).replace("|", "/")
        return re.sub(r"\s+", " ", v).strip() or "none"
    return f"delivery: stage={stage} | next={clean(step)} | owner={clean(owner)} | changed={changed}"


def next_step(x):
    """The row's next step as plain text: the sentence after **Next:** in `next`, else its first sentence."""
    text = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", x.get("next", "")))).strip()
    after = re.split(r"\b(?:Next|Waiting on):\s*", text, maxsplit=1)
    text = after[1] if len(after) > 1 else text
    return re.split(r"(?<=[.!?])\s", text, maxsplit=1)[0].rstrip(".") if text else ""


def delivery(x, date, merged_for=None):
    """Delivery line for a ticket or MR row. An explicit "stage" wins. Else: a merged MR is merged and an open one in review;
    a Done ticket is done, a ticket whose MR is merged on this board (merged_for: ticket id -> merged row) or that is in
    Staging is merged, any other ticket in review. next is the real next step: finish.step, progress.pending, the production
    apply/release of a merged row, else the step written in the row's `next`. changed is "updated" or the board date."""
    linked = (merged_for or {}).get(x.get("id"))
    if x.get("_closed"):
        stage = "done"
    elif x.get("stage"):
        stage = x["stage"]
    elif "refs" in x:
        stage = "merged" if x.get("_ship") else "review"
    elif x.get("status") == "Done":
        stage = "done"
    else:
        stage = "merged" if linked or x.get("status") == "Staging" else "review"
    f, pr = x.get("finish") or {}, x.get("progress") or {}
    ship = x.get("_ship") or (linked or {}).get("_ship")
    step = "none" if stage == "done" else (f.get("step") or pr.get("pending") or (f"production {ship}" if ship else "")
                                           or next_step(x) or x.get("label", ""))
    owner = f.get("owner") or pr.get("owner") or x.get("owner") or "You"
    return delivery_line(stage, step, owner, str(x.get("updated") or date))


def check_standalone(dec, t, m):
    """The Decisions section is only for decisions with no ticket or MR: one that blocks a row goes on that row."""
    rows = {norm(x["id"], "t"): x["id"] for x in t} | {norm(r[1], "mr"): r[1] for x in m for r in x["refs"]}
    for x in dec:
        named = x.get("ticket") or x.get("mr") or ""
        hit = norm(x["id"], "t") in rows or norm(x["id"], "mr") in rows or (named and norm(named) in rows)
        if named or hit:
            raise ValueError(f"decision {x['id']} belongs on its ticket or MR row: put `decision` on "
                             f"{named or x['id']} instead of a standalone decision")


def check_outward_draft(x, ref):
    """An option that posts text must show that exact text on its card, so the row needs a draft."""
    if posts_text(x) and draft_text(x) is None:
        names = ", ".join(o["label"] for o in x["decision"]["options"] if o.get("outward"))
        raise ValueError(f"outward decision option ({names}) on {ref} has no draft to show: give the row `draft` or a "
                         "readable `draft_file` with the exact text it posts")


def check_decision(x, ref):
    opts = (x.get("decision") or {}).get("options") or []
    rec = sum(1 for o in opts if o.get("recommended"))
    if not 1 <= len(opts) <= 4 or rec > 1 or (len(opts) > 1 and rec != 1) or not x["decision"].get("question") \
            or any(not (o.get("label") and o.get("consequence") and o.get("prompt")) for o in opts):
        raise ValueError(f"bad decision on {ref}: a question, 1 to 4 options with label, consequence and "
                         "prompt, and exactly one recommended when there are several")


def decision_actions(x):
    return [{"label": o["label"], "prompt": o["prompt"], "outward": o.get("outward", False), "_opt": True}
            for o in (x.get("decision") or {}).get("options", [])]


def share_decisions(rows, ids):
    """A decision renders in full once, on its owning row; a row it also blocks says `decision_ref` and gets a pointer line."""
    by = {ref: x for x, ref in rows}
    seen = {}
    for x, ref in rows:
        q = (x.get("decision") or {}).get("question")
        if q and not x.get("decided"):
            if q in seen:
                raise ValueError(f"{ref} and {seen[q]} carry the same decision question: keep it on the owning row and give "
                                 f'the other `"decision_ref": "<owning ref>"` so it renders once')
            seen[q] = ref
    for x, ref in rows:
        src = x.get("decision_ref")
        if not src:
            continue
        o = by.get(src)
        if o is None or (not o.get("decision") and o is not x):  # owner gone or its decision closed: drop the pointer
            x.pop("decision_ref")
            print(f"warning: {ref}: decision_ref {src} names no row with a decision; pointer dropped", file=sys.stderr)
            continue
        if o is x:
            raise ValueError(f"{ref}: decision_ref {src} names no row with a decision")
        if x.get("decision"):
            raise ValueError(f"{ref} has decision_ref and its own decision: the decision lives on {src} only")
        x["_dptr"] = {"ref": src, "id": ids[src]}
        if o.get("decided") and not x.get("decided"):
            x["decided"] = o["decided"]
    for x, ref in rows:
        for o, oref in rows:
            multi = (o.get("decision") or {}).get("options") or []
            if o is x or len(multi) < 2 or x.get("decision"):
                continue
            hit = {a["label"] for a in x.get("actions") or []} & {m["label"] for m in multi}
            if hit:
                raise ValueError(f"{ref} shows option {sorted(hit)[0]!r} of the decision on {oref} as a plain action: "
                                 f'give {ref} "decision_ref": "{oref}" so it points to the owning card')


def merge_ready(x):
    """merge_state is all clear: no conflicts, green pipeline, approved (or none required), a known open-thread count.
    Open threads do not block: the author resolves them after the final feedback check (Resolve and merge).
    The pipeline is either on the real head (default scope) or, in a project that runs only merge-result pipelines
    (pipeline_scope "merge_result"), the green merge-result run for the current head (merge_result_current true)."""
    m = x.get("merge_state") or {}
    scope = m.get("pipeline_scope", "head")
    if scope == "head":
        pipe_ok = m.get("pipeline_on_head") is True
    else:
        pipe_ok = scope == "merge_result" and m.get("merge_result_current") is True
    threads = m.get("open_threads")
    return bool(m and m.get("conflicts") is False and m.get("pipeline") == "success" and pipe_ok
                and m.get("approved") in (True, "not_required") and type(threads) is int and threads >= 0
                and not m.get("draft"))


def own_mr(x, user):
    if x.get("role"):
        return x["role"] != "reviewer"
    return x["author"].lower() in SELF | {user.lower()}


MERGE_LABELS = ("Merge", "Resolve and merge")


def merge_prompt(x):
    """Merge re-checks live and merges; Resolve and merge first gives every open thread a verdict and stops on any that needs work."""
    url = x["refs"][0][0]
    mr_scope = x["merge_state"].get("pipeline_scope") == "merge_result"
    recheck = ("re-check live right now (the PR-status helper if installed, else glab mr view and the pipeline "
               + ("of the latest merge-result run for the current head" if mr_scope else "of the real head SHA") + "): "
               "conflicts, pipeline green, approvals. " + (
                   "This project runs only merge-result pipelines: no pipeline runs at the head SHA, so accept the green "
                   "merge-result pipeline created for the current head (it must be newer than the last push) in place of a head pipeline. "
                   if mr_scope else "The pipeline must have run on the real head SHA. "))
    if not x["merge_state"]["open_threads"]:
        return (f"Re-check {url}: {recheck}Also check that no thread is unresolved. Merge only if every condition still holds; "
                "otherwise do not merge and report which one failed. Never apply or delete.")
    return (f"Resolve and merge {url}. The user is the author; here the author resolves threads after checking them, not the reviewer. "
            "1) Final feedback check: read every open thread live, bot and human, and give each one a verdict: actioned (a later "
            "commit or reply already addresses it), not actionable (informational, or a bot finding that warrants no change), "
            "or needs work (it still needs a code change or a reply from the author). A human question or request that nobody "
            "answered is always needs work, never not actionable. "
            "2) If any thread needs work, stop: resolve nothing, merge nothing, and list those threads (link, author, what is "
            "missing) in chat and on this row with board_state.py. "
            f"3) Only if none needs work: {recheck}If every condition holds, resolve every open thread, then merge (the same "
            "steps whether or not the project requires resolved discussions); otherwise do not merge and report which one "
            "failed. Report each thread's verdict. Never apply or delete.")


def load_facts(b, src, collect):
    """Facts by MR URL from a collect_mrs.py --format json file (CLI flag, else board.json "collect"); {} when none."""
    path = collect or b.get("collect")
    if not path:
        return {}
    p = Path(path).expanduser()
    p = p if p.is_absolute() else Path(src).resolve().parent / p
    return {f["url"].rstrip("/"): f for f in json.loads(p.read_text())["mrs"] if f.get("url")}


NOT_READY = re.compile(r"not\s+(yet\s+)?(merge[- ]?ready|ready(\s+to\s+merge)?|mergeable)|do(n't|\s+not)\s+merge", re.I)
DEFAULT_BRANCHES = ("main", "master")


def unmerged_deps(x, mrs, facts):
    """Refs this MR waits on: its `depends_on` MRs that are not merged (a merged row on the board, or collect facts saying
    merged; one nobody can confirm counts as unmerged), plus its parent when its target branch is not main or master."""
    out = []
    for dep in ([x["depends_on"]] if isinstance(x.get("depends_on"), str) else x.get("depends_on") or []):
        row = next((y for y in mrs if y is not x and norm(dep, "mr") in {norm(r[1], "mr") for r in y["refs"]}), None)
        short = re.match(r"([\w/-]+)\s?!(\d+)", dep)
        fact = next((f for f in facts.values() if short and PROJECTS.get(short.group(1), "").split("/")[-1] == f.get("project")
                     and str(f.get("iid")) == short.group(2)), None)
        if not ((row and row.get("merged")) or (fact and fact.get("state") == "merged")):
            out.append(dep)
    branch = (x.get("_fact") or {}).get("target_branch")
    if branch and branch not in DEFAULT_BRANCHES:
        out.append(f"branch {branch}")
    return out


def apply_facts(mrs, facts, user):
    """Attach each row's facts and derive its merge_state from them unless the row carries one. Nothing is derived for a row
    that is on hold or blocked, whose label says it is not merge-ready, or that waits on another unmerged MR (`_waits`)."""
    for x in mrs:
        f = next((facts[u.rstrip("/")] for u, *_ in x["refs"] if u.rstrip("/") in facts), None)
        x["_fact"] = f
    for x in mrs:
        x["_waits"] = unmerged_deps(x, mrs, facts)
        held = x.get("verdict") in ("hold", "blocked") or NOT_READY.search(f"{x.get('label', '')} {x.get('headline', '')}")
        f = x["_fact"]
        if f and not x.get("merged") and own_mr(x, user) and "merge_state" not in x and not held and not x["_waits"]:
            ms = mr_steps.merge_state(f)
            if ms:
                x["merge_state"] = ms


def has_open_decision(x):
    return bool(x.get("decision")) and not x.get("decided")


def only_rechecks(x):
    return all(a["label"].lower().startswith("re-check") for a in x.get("actions") or [])


def lift_review(mrs, user, template):
    """A review report on disk for an MR the user reviews: its comment draft becomes drafts boxes (Post each), Approve when
    the report says safe, and a "Show the review" button otherwise. Never overrides drafts the row already carries."""
    for x in mrs:
        if x.get("merged") or own_mr(x, user):
            continue
        d = mr_steps.report_dir(x, template)
        if not d:
            continue
        ref, url = x["refs"][0][1], x["refs"][0][0]
        x["_reviewed"] = True
        if not (x.get("drafts") or x.get("draft") or x.get("draft_file")):
            ds = mr_steps.report_drafts(d)
            x["drafts"] = [{"id": f"d{i}", "target": ref if t == "Comment" else f"{ref}: {t}", "target_url": url, "text": c}
                           for i, (t, c) in enumerate(ds)]
            if ds:
                x["chips"] = list(x.get("chips") or []) + ["Drafts waiting for your go"]
        acts = [a for a in x.get("actions") or [] if a["label"] not in ("Approve", "Show the review")]
        if mr_steps.report_safe_to_approve(d):
            acts.insert(0, {"label": "Approve", "outward": True, "prompt":
                            f"Approve {url} with glab mr approve, only after a live check that the head SHA did not change since the "
                            f"review in {d / 'report.md'} and that the pipeline on the head is not red. Post nothing else."})
        else:
            show = {"label": "Show the review", "outward": False, "prompt":
                    f"Show the verdict, the findings and the exact comment drafts from {d / 'report.md'} for {url}. "
                    "Read-only; post and approve nothing."}
            acts.insert(0 if only_rechecks(dict(actions=acts)) else len(acts), show)
        x["actions"] = acts


def add_steps(mrs, user):
    """Give every row whose state names a step a first button that performs it, moving a hand-written one to the front.
    Row "step" wins, then the live facts, then the label. A row with an open decision keeps its options as the actions."""
    for x in mrs:
        if x.get("merged") or has_open_decision(x):
            continue
        own, f = own_mr(x, user), x.get("_fact")
        name = x.get("step")
        if name and name != "none" and name not in mr_steps.STEPS:
            raise ValueError(f"{x['refs'][0][1]}: unknown step {name!r}; use one of {', '.join(mr_steps.STEPS)} or none")
        if name is None:
            name = mr_steps.step(f, own) if f else (mr_steps.step_from_label(x.get("label"), own) if x.get("verdict") != "hold" else None)
        if name in (None, "none") or (name == "review" and x.get("_reviewed")):
            continue
        act = mr_steps.step_action(name, x["refs"][0][0], f)
        rest = [a for a in x.get("actions") or [] if a["label"] != act["label"]]
        x["actions"] = [next((a for a in x.get("actions") or [] if a["label"] == act["label"]), act)] + rest


def inherit_buttons(tickets, mrs, user):
    """A ticket row takes the step and merge buttons of its own MR rows, so it is never left with only Re-check state.
    Linked by the ticket's `mr` (ref or list), the MR row's `ticket`, or the ticket id in the MR's title. With several
    MRs each label gets the MR's ref."""
    mine = [x for x in mrs if not x.get("merged") and own_mr(x, user)]
    for t in tickets:
        if has_open_decision(t):
            continue
        named = {norm(r, "mr") for r in ([t["mr"]] if isinstance(t.get("mr"), str) else t.get("mr") or [])}
        linked = [x for x in mine if t["id"].upper() in mr_steps.mr_ticket_ids(x)
                  or any(norm(r[1], "mr") in named for r in x["refs"])]
        got = [(x, a) for x in linked for a in x.get("actions") or []
               if a["label"] in set(mr_steps.STEPS.values()) | set(MERGE_LABELS)]
        many = len({id(x) for x, _ in got}) > 1
        mine_acts = [dict(a, label=f"{a['label']} · {x['refs'][0][1]}" if many else a["label"]) for x, a in got]
        have = {a["label"] for a in t.get("actions") or []}
        t["actions"] = [a for a in mine_acts if a["label"] not in have] + list(t.get("actions") or [])


def add_merge(mrs, user):
    """Merge (no open threads) or Resolve and merge (open threads) only on the user's own mergeable MRs; a
    hand-written one elsewhere aborts. Apply and delete never."""
    for x in mrs:
        ref = x["refs"][0][1]
        labels = [a["label"] for a in x.get("actions") or []]
        ok = own_mr(x, user) and merge_ready(x) and not x.get("merged") and not x.get("_waits")
        want = ("Resolve and merge" if x["merge_state"]["open_threads"] else "Merge") if ok else None
        for l in MERGE_LABELS:
            if l in labels and l != want:
                raise ValueError(f"{ref}: {l} is added by render.py, never by hand. Merge only on the user's own MR with merge_state "
                                 "clear (no conflicts, pipeline success on the head, or on the current merge-result run with "
                                 "pipeline_scope merge_result, approved or not_required, a known open_threads count): "
                                 "Merge with 0 open threads, Resolve and merge with open threads")
        if ok:
            x["_mergeable"] = True
            if want not in labels:
                x["actions"] = [{"label": want, "outward": True, "prompt": merge_prompt(x)}] + list(x.get("actions") or [])
        bad = [l for l in labels if l.split()[0].lower() in ("apply", "delete")]
        if bad:
            raise ValueError(f"{ref}: apply and delete are never offered as buttons ({bad[0]})")


SHIPS_FILE = org.CONFIG  # the "ships" key of the local org config
CLOSED = {"done", "canceled", "cancelled"}
DONE_WORD = {"apply": "applied", "release": "released"}


def ship_step(x):
    """'apply' or 'release' when the MR's project ships to production only after a separate step (ships.json), else None.
    The project comes from the MR URL (gitlab.com/<group>/<path>/-/merge_requests/) or the short ref (pi !1937)."""
    ships = org.SHIPS
    url, label = x["refs"][0][0], x["refs"][0][1]
    m = re.search(r"gitlab\.com/(?:" + re.escape(org.GITLAB_GROUP) + r"/)?(.+?)/-/merge_requests/", url)
    short = re.match(r"([a-z-]+)\s?!", label)
    for project in ((m.group(1) if m else None), PROJECTS.get(short.group(1)) if short else None):
        for step in ("apply", "release"):
            if project and project in ships.get(step, []):
                return step
    return None


def merged_rows(b, user):
    """A merged MR of the user's in a project where nothing ships on merge stays as 'Merged, <step> not confirmed'
    until the user's note (chat or the Mark button) or until its ticket is Done/Canceled; returns the rows it closed."""
    keep, closed = [], []
    for x in b["mrs"]:
        if not x.get("merged"):
            keep.append(x)
            continue
        ref, step = x["refs"][0][1], ship_step(x)
        if not step or not own_mr(x, user):
            raise ValueError(f"{ref}: a merged MR stays on the board only when it is the user's own and its project needs a "
                             f"production apply or release ({SHIPS_FILE.name}); drop it from board.json otherwise")
        if str(x.get("ticket_status", "")).lower() in CLOSED:
            closed.append(dict(x, _closed=f"ticket {x.get('ticket', '')} is {x['ticket_status']}".replace("  ", " ")))
            continue
        x["_ship"] = step
        x["label"] = f"Merged, {step} not confirmed"
        x.setdefault("verdict", "notyet")
        x.setdefault("owner", "You")
        done = DONE_WORD[step]
        x.setdefault("next", f"Merged. Nothing reaches production on merge here: <b>Next:</b> the production {step}, then "
                             f"say \"{done} {ref}\" in any session or click Mark {done}.")
        ticket = x.get("ticket")
        x["actions"] = [a for a in x.get("actions") or [] if a["label"] != f"Mark {done}"]  # render.py writes this one
        x["actions"] = [{"label": f"Mark {done}", "outward": True, "prompt":
                         f"Mark {done} on {ref} ({x['refs'][0][0]}): the user confirms it is {done} in production (production "
                         "only; staging never counts). 1) buddy_merge(kind='task_update', task_key='" + task_key(x) + "', "
                         f"task_status='done') with the task's content plus a dated line '{done} in production (user's note)', and its delivery "
                         "line set to stage=applied (stage=done once the ticket is Done, or with no ticket). "
                         + (f"2) Read {ticket}'s acceptance criteria and check each against live evidence: the merged MR, this note, "
                            "monitors, staging proof links on the ticket. If all are met, set the ticket Done and list the evidence "
                            "per criterion in chat; if not, keep it open and write the gap (the unmet criteria) on this row and on "
                            "the ticket's row with board_state.py. Never post a Linear comment unless the user approves its exact text. "
                            if ticket else "2) No ticket is linked: nothing to close. ")
                         + "3) Mark this row done with board_state.py (done_actions, progress)."}] + list(x.get("actions") or [])
        keep.append(x)
    b["mrs"] = keep
    return closed


def real_actions(x, ref, user=""):
    """Decision options, explicit actions, plus the default Nudge for a hold row owned by someone else."""
    acts = ([] if x.get("decided") else decision_actions(x)) + [a for a in (x.get("actions") or []) if a["label"] not in ("Nevermind", "Add context", "Wait, what?")]
    owner = x.get("owner", "")
    if x.get("verdict") == "hold" and owner and not has_self(owner, user):
        label = f"Nudge {owner}"
        if label not in [a["label"] for a in acts]:
            acts.append({"label": label, "outward": True, "prompt":
                         f"Draft a short nudge to {owner} about {ref} with the user's writing-voice skill. "
                         "Show the exact text and the channel, post only after the user confirms."})
    return acts


def standard_actions(x, ref):
    """The Wait, what? and Nevermind buttons every row gets (never outward); shared by the page and the feed."""
    never = {"label": "Nevermind", "prompt": f"Nevermind on {ref}: post and message nothing; "
             f"set the row's task ({task_key(x)}) to abandoned with buddy_merge(kind='task_update'), then append "
             '{"key": "' + task_key(x) + '", "date": "<today>"} to ~/.config/linear-action-board/abandoned.json '
             "(that file is what later builds read)."}
    wtf = {"label": "Wait, what?", "prompt": (
        f"Wait, what? on {ref}: run the wait-what skill on this card (use it if installed, else do what it does): "
        "re-explain the card's situation in plain English, adding the premise that is missing, in the vocabulary of the "
        f"project. Write it back to the card with board_state.py (board-state.json) as an explained block {{text, at}} for this row "
        f"(task {task_key(x)}); change nothing else, post and message nothing.")}
    return wtf, never


def actions(x, ref, user=""):
    """All buttons inline: the first filled, Wait, what?, Add context, then Nevermind as a small 'dismiss' at the far right."""
    if not LAVISH:
        return ""
    acts = [a for a in real_actions(x, ref, user) if not a.get("_opt")]
    ctx = {"ref": ref, "key": task_key(x)}
    deciding = bool(x.get("decision")) and not x.get("decided")  # the option cards are the primary actions: no filled button beside them
    wtf, never = standard_actions(x, ref)
    explained = bool((x.get("explained") or {}).get("text"))
    saved = bool(x.get("cards") or x.get("context_saved"))
    rest = "".join(act_button(ref, a) for a in acts[0 if deciding else 1:]) + act_button(
        ref, wtf, "act wtf" + (" ready" if explained else ""), "Wait, what? · explained" if explained else None) + (
        f'<button type="button" class="act ctx{" ready" if saved else ""}" data-ctx="{html.escape(json.dumps(ctx), quote=True)}">'
        f'{"Add context · saved" if saved else "Add context"}</button>')
    primary = act_button(ref, acts[0], "act primary") if acts and not deciding else ""
    return '<div class="acts">' + primary + rest + act_button(ref, never, "act dismiss", "dismiss") + "</div>"


def act_button(ref, a, cls="act", text=None):
    data = html.escape(json.dumps({"ref": ref, "label": a["label"], "prompt": a["prompt"],
                                   "outward": bool(a.get("outward"))}), quote=True)
    cls += " outward" if a.get("outward") else ""
    return f'<button type="button" class="{cls}" data-act="{data}">{html.escape(text or a["label"])}</button>'


def decided_line(x):
    d = x.get("decided")
    at = f" · {html.escape(d['at'])}" if d.get("at") else ""
    return f'<div class="decided">Decided: {html.escape(d["option"])}{at}</div>'


def decision_block(x, ref):
    if x.get("decided"):  # the landed decision is dismissed: a one-line record instead of the option cards
        return decided_line(x)
    d = x.get("decision")
    if x.get("_dptr"):
        p = x["_dptr"]
        return (f'<div class="dptr" data-dref="{html.escape(p["id"])}">Decision on '
                f'<a class="dlink" href="#{html.escape(p["id"])}">{html.escape(p["ref"])}</a></div>')
    if not d:
        return ""
    cards_ = []
    for o in d["options"]:
        rec = o.get("recommended")
        body = f'<b>{html.escape(o["label"])}</b><small>{html.escape(o["consequence"])}</small>'
        if LAVISH:
            cards_.append(act_button(ref, o, "act opt" + (" rec" if rec else ""), None).replace(
                f">{html.escape(o['label'])}</button>", f">{body}</button>"))
        else:
            cards_.append(f'<div class="opt{" rec" if rec else ""}">{body}</div>')
    text = draft_text(x) if posts_text(x) else None
    shown = (f'<div class="ddraft"><div class="ddh">Exact text the outward option posts</div>'
             f'<pre>{html.escape(text)}</pre></div>') if text else ""
    return (f'<div class="decision"><div class="dq">{html.escape(d["question"])}</div>{shown}'
            f'<div class="opts">{"".join(cards_)}</div></div>')


def cards(x):
    items = x.get("cards") or []
    if not items:
        return ""
    links = ", ".join(link(c["url"], c["title"]) if c.get("url") else
                      f'{html.escape(c["title"])} <code>{html.escape(c["slug"])}</code>' for c in items)
    return f'<div class="cards">Brain: {links}</div>'


def explained_html(x):
    e = x.get("explained")
    if not e or not e.get("text"):
        return ""
    at = f' <small>{html.escape(e["at"])}</small>' if e.get("at") else ""
    return f'<div class="explained"><b>In plain English</b>{at}<div class="etext">{html.escape(e["text"])}</div></div>'


def note_draft(x, ref):
    d = x.get("note_draft")
    if not LAVISH or not d:
        return ""
    meta = html.escape(json.dumps({"ref": ref, "kind": d["kind"], "target": d["target"]}), quote=True)
    return (f'<div class="ndraft" data-nd="{meta}"><div class="ndh">Draft {html.escape(d["kind"])} to '
            f'{html.escape(d["target"])} (not posted)</div><textarea class="ndt" readonly>{html.escape(d["text"])}</textarea>'
            '<div class="acts"><button type="button" class="act outward nd-post">Post</button>'
            '<button type="button" class="act nd-edit">Edit</button>'
            '<button type="button" class="act nd-discard">Discard</button></div></div>')


def check_drafts(x, ref):
    ids = [d.get("id") for d in x.get("drafts") or []]
    if len(set(ids)) != len(ids) or any(not (d.get("id") and d.get("target") and d.get("text")) for d in x.get("drafts") or []):
        raise ValueError(f"bad drafts on {ref}: each draft needs a unique id, a target and its text")


def drafts_html(x, ref):
    """One editable box per drafted message: target (linked), text, its own Post / Discard; posted ones are locked."""
    out = []
    for d in x.get("drafts") or []:
        tgt = link(d["target_url"], d["target"]) if d.get("target_url") else html.escape(d["target"])
        posted = d.get("posted_at")
        state = f"Posted at {html.escape(posted)}" if posted else "not posted"
        meta = html.escape(json.dumps({"ref": ref, "id": d["id"], "target": d["target"], "url": d.get("target_url", "")}), quote=True)
        btns = ('<div class="acts dacts"><button type="button" class="act outward d-post">Post</button>'
                '<button type="button" class="act d-discard">Discard</button></div>') if LAVISH and not posted else ""
        ro = "" if LAVISH and not posted else " readonly"
        out.append(f'<div class="dbox{" posted" if posted else ""}" data-did="{html.escape(d["id"], quote=True)}" data-d="{meta}">'
                   f'<div class="dh"><span>Reply to {tgt}</span> <span class="dstate">{state}</span></div>'
                   f'<textarea class="dt"{ro}>{html.escape(d["text"])}</textarea>{btns}</div>')
    return "".join(out)


STAGES = ["To Do", "In Progress", "In Review", "Staging", "Done"]


def lane(x, user=""):
    """decide: a decision is open; waiting: someone else owes the next step; do: the user does it."""
    if (x.get("decision") or x.get("_dptr")) and not x.get("decided"):
        return "decide"
    return "waiting" if waiting_on_others(x, user) and not x.get("_mergeable") else "do"


def stage_index(x):
    return STAGES.index(x["status"]) if x.get("status") in STAGES else -1


def finish_parts(x):
    """(step, owner) left to Done for a row, ("", owner) when none is named."""
    f = x.get("finish") or {}
    only = re.fullmatch(r"only (?:the )?(.+?) left", x.get("label", "").strip(), re.I)
    step = f.get("step") or (x.get("progress") or {}).get("pending") or (only.group(1) if only else "")
    owner = f.get("owner") or (x.get("progress") or {}).get("owner") or x.get("owner", "")
    return step, owner


def finish_step(x):
    step, owner = finish_parts(x)
    return f"{step}, {'you' if owner.lower() in SELF else owner}" if step else ""


STATUS_COLORS = {"To Do": "#ffffff", "In Progress": "#f2c94c", "In Review": "#f2994a",
                 "Staging": "#2bb5a0", "Done": "#74a7f7"}
STATE_COLORS = {}


def state_color(name):
    """Pill color for a Linear status: board.json 'state_colors' first, then the built-in color, else light grey."""
    color = STATE_COLORS.get(name) or STATUS_COLORS.get(name, "#e2e2e2")
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
        raise ValueError(f"bad color {color!r} for state {name!r}: use #rrggbb")
    return color.lower()


def luminance(hex_color):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex_color[i:i + 2], 16) for i in (1, 3, 5))
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def text_on(hex_color):
    """Dark or white text, whichever contrasts more with the chip color (readable in light and dark pages)."""
    lum = luminance(hex_color)
    return "#141413" if (lum + 0.05) / 0.05 >= 1.05 / (lum + 0.05) else "#ffffff"


def track(x):
    """One flat, non-interactive pill with the current Linear status, plus the step left to Done as plain text."""
    status = x.get("status")
    if not status:
        return ""
    bg = state_color(status)
    border = "#9aa5a0" if bg == "#ffffff" else bg
    fin = finish_step(x)
    return (f'<div class="statusline"><span class="status" style="background:{bg};color:{text_on(bg)};'
            f'border-color:{border}">{html.escape(status)}</span>'
            + (f'<span class="finish">Done: {html.escape(fin)}</span>' if fin and status != "Done" else "") + "</div>")


def one_line(x):
    text = x.get("why") or html.unescape(re.sub(r"<[^>]+>", "", x.get("next", ""))).strip()
    if not x.get("why"):
        text = re.split(r"(?<=[.!?])\s", text, maxsplit=1)[0]
    return html.escape(text if len(text) <= 140 else text[:139] + "…")


def headline(x, ref, user):
    if x.get("headline"):
        return x["headline"]
    acts = [a for a in real_actions(x, ref, user) if not a.get("_opt")]
    return acts[0]["label"] if acts else x["what"]


def row_html(x, rid, ref, ref_html, user, meta="", with_track=False):
    meta_line = f'<div class="meta">{meta}</div>' if meta else ""
    return (f'<div class="row" id="{html.escape(rid)}" data-chips="{" ".join(x.get("_chips", []))}"><div class="stripe {x["verdict"]}"></div><div class="rbody">'
            f'<div class="rtop"><span class="verb">{html.escape(headline(x, ref, user))}</span>'
            f'<span class="ref">{ref_html}</span><span class="vc">{pill(x["verdict"], x["label"])}</span>'
            f'<span class="owner">{html.escape(x.get("owner", "You"))}</span></div>'
            f'{track(x) if with_track else ""}{progress(x)}{explained_html(x)}{decision_block(x, ref)}'
            f'<details class="ctxd"><summary class="why">{one_line(x)}</summary>{meta_line}'
            f'<div class="nx">{autolink(x.get("next", ""))}</div>{draft(x)}{cards(x)}</details>'
            f'{note_draft(x, ref)}{drafts_html(x, ref)}{actions(x, ref, user)}</div></div>')


def chip_key(label):
    return re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")


def tag_rows(t, m, others):
    """Each card gets the keys of the chips that count it; the counts and the filter both read these."""
    for x in t + m + others:
        x["_chips"] = [chip_key(c) for c in x.get("chips", [])]
    for x in t:
        x["_chips"].append("tickets")
    for x in t + m:
        if x["verdict"] == "close":
            x["_chips"].append("act-now")
        if x["verdict"] == "hold":
            x["_chips"].append("waiting-on-others")
    for x in m:
        if x.get("_mergeable"):  # Merge or Resolve and merge: the user can act now, whoever the row names as owner
            x["_chips"] += ["mergeable-now"] + ([] if "act-now" in x["_chips"] else ["act-now"])


def chip_bar(t, m, others, extra):
    """A chip with cards behind it filters (multi-select, union); one without stays a plain count."""
    rows = t + m + others
    labels = {"Tickets": "tickets", "Act now": "act-now", "Waiting on others": "waiting-on-others"}
    for k in list(extra) + [c for x in rows for c in x.get("chips", [])] + (["Mergeable now"] if any("mergeable-now" in x["_chips"] for x in rows) else []):
        labels.setdefault(k, chip_key(k))
    out = []
    for label, key in labels.items():
        n = sum(1 for x in rows if key in x["_chips"])
        if n:
            out.append(f'  <button type="button" class="chip" data-chip="{key}" aria-pressed="false">{html.escape(label)} <b>{n}</b></button>')
        else:
            out.append(f'  <span class="chip">{html.escape(label)} <b>{html.escape(str(extra.get(label, 0)))}</b></span>')
    return "\n".join(out)


def lanes(items, user, key=lambda x: 0):
    """items: (x, html). Decide, then Do, then Waiting collapsed; key sorts inside a lane (lower first)."""
    out = []
    for name, title in (("decide", "Decide"), ("do", "Do"), ("waiting", "Waiting")):
        rows = sorted((i for i in items if lane(i[0], user) == name), key=lambda i: key(i[0]))
        if not rows:
            continue
        body = "".join(h for _, h in rows)
        out.append(f'<details class="waiting fg"><summary>Waiting · {len(rows)}</summary>{body}</details>' if name == "waiting"
                   else f'<div class="lg fg"><h4 class="lane">{title}</h4>{body}</div>')
    return '<div class="board">' + "".join(out) + "</div>" if out else ""


FILTER_JS = """
<script>
// Header chips are multi-select filters: a card shows when it carries any active chip's key.
var activeChips = [];
function chipKeys(row) { return (row.getAttribute('data-chips') || '').split(' ').filter(Boolean); }
function applyChipFilter() {
  var rows = document.querySelectorAll('.row'), i, j;
  for (i = 0; i < rows.length; i++) {
    var keys = chipKeys(rows[i]);
    rows[i].hidden = activeChips.length > 0 && !activeChips.some(function (c) { return keys.indexOf(c) >= 0; });
  }
  var chips = document.querySelectorAll('button.chip[data-chip]');
  for (i = 0; i < chips.length; i++) {
    var key = chips[i].getAttribute('data-chip'), n = 0, on = activeChips.indexOf(key) >= 0;
    for (j = 0; j < rows.length; j++) if (chipKeys(rows[j]).indexOf(key) >= 0) n++;
    chips[i].querySelector('b').textContent = n;
    chips[i].setAttribute('aria-pressed', on ? 'true' : 'false'); chips[i].classList.toggle('on', on);
  }
  var groups = document.querySelectorAll('.fg, section');
  for (i = 0; i < groups.length; i++) {
    var has = !!groups[i].querySelector('.row:not([hidden])');
    groups[i].hidden = activeChips.length > 0 && !has;
    if (activeChips.length && has && groups[i].tagName === 'DETAILS') groups[i].open = true;
  }
}
document.addEventListener('click', function (e) {
  var a = e.target.closest ? e.target.closest('a.dlink') : null;
  if (a) {  // pointer line: scroll to the card that owns the decision and flash it
    var t = document.getElementById((a.getAttribute('href') || '').slice(1)); if (!t) return;
    e.preventDefault(); var dt = t.closest('details'); if (dt) dt.open = true;
    if (t.scrollIntoView) t.scrollIntoView({behavior: 'smooth', block: 'center'});
    t.classList.add('flash'); setTimeout(function () { t.classList.remove('flash'); }, 1600);
    return;
  }
  var c = e.target.closest ? e.target.closest('button.chip[data-chip]') : null;
  if (!c) return;
  var k = c.getAttribute('data-chip'), at = activeChips.indexOf(k);
  if (at >= 0) activeChips.splice(at, 1); else activeChips.push(k);
  applyChipFilter();
});
</script>
"""

LAVISH_JS = """
<style>
.acts{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
.act{font:inherit;font-size:12px;padding:3px 9px;border-radius:6px;border:1px solid currentColor;background:transparent;color:inherit;cursor:pointer;opacity:.85}
.act:hover{opacity:1}.act.outward{border-style:dashed}
.act.queued{opacity:.5;cursor:default}
.act.confirm{background:#b45309;color:#fff;border-color:#b45309}
.prog{font-size:12px;margin-bottom:6px;padding:4px 8px;border-left:3px solid currentColor;opacity:.9}
.prog ul{margin:0;padding-left:16px}.prog .pend{font-weight:600;margin-top:2px}
.act.done{opacity:.4;cursor:default;text-decoration:line-through}
.acts{align-items:center}.act.primary{background:var(--accent);border-color:var(--accent);color:var(--surface);font-weight:500;opacity:1}
.act.dismiss{margin-left:auto;border:none;font-size:11.5px;color:var(--muted);text-decoration:underline dotted}
.act.opt{text-align:left;border-radius:8px;padding:8px 10px;opacity:1}.act.opt.queued{outline:2px solid var(--warn)}
.opt.confirm::after{content:"click again to confirm";font-size:11px;color:#fff}
.explained{padding:6px 8px;border-left:3px solid var(--info);background:var(--info-bg);font-size:13px}.explained .etext{white-space:pre-wrap;margin-top:2px}
.act.pending{background:var(--warn-bg);color:var(--warn);border-color:var(--warn);opacity:1}
.act.ready{background:var(--ok-bg);color:var(--ok);border-color:var(--ok);opacity:1}
.act.wtf.queued{cursor:default}
.row[hidden]{display:none}
.sentbadge{font-family:"IBM Plex Mono",monospace;font-size:11px;color:var(--muted);border:1px solid var(--line);padding:1px 8px;border-radius:99px}
.queuedbadge{font-family:"IBM Plex Mono",monospace;font-size:11px;color:var(--warn);background:var(--warn-bg);padding:1px 8px;border-radius:99px}
#sendbar{position:sticky;bottom:0;display:flex;gap:10px;align-items:center;justify-content:space-between;padding:10px 16px;background:var(--warn-bg);border:1px solid var(--warn);border-radius:8px;font-size:13px}
#sendbar[hidden]{display:none}
.cards{font-size:12px;margin-top:6px}
.ndraft{margin-top:8px;padding:6px 8px;border:1px dashed currentColor;border-radius:6px}.ndh{font-size:12px;font-weight:600}
.dbox{margin-top:8px;padding:6px 8px;border:1px solid var(--card-line);border-radius:8px}.dbox.posted{opacity:.7}
.dh{font-size:12px;font-weight:600;display:flex;justify-content:space-between;gap:8px}.dstate{font-weight:400;color:var(--muted)}.dbox.posted .dstate{color:var(--ok)}
.dt{width:100%;min-height:70px;font:inherit;font-size:12px;margin-top:4px;box-sizing:border-box}
.ndt{width:100%;min-height:70px;font:inherit;font-size:12px;margin-top:4px;box-sizing:border-box}
.ctxm{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:9}
.ctxm div{background:var(--surface,#fff);color:var(--ink,#000);padding:14px;border-radius:8px;width:min(480px,90vw)}
.ctxm textarea{width:100%;min-height:110px;font:inherit;box-sizing:border-box}
</style>
<script>
// Annotation starts off: the board is for buttons. The chrome only trusts messages that carry the SDK's
// load token, so press the SDK's own Ctrl+I toggle once per load (the toolbar can turn it back on).
var lavishAnnotOffDone = false;
window.addEventListener('message', function (e) {
  var d = e.data || {};
  if (d.type === 'lavish:setAnnotationMode' && d.enabled && !lavishAnnotOffDone) {
    lavishAnnotOffDone = true;
    document.dispatchEvent(new KeyboardEvent('keydown', {key: 'i', ctrlKey: true, bubbles: true, cancelable: true}));
  }
});
function setState(b, state, text) {
  if (!b) return;
  b.classList.remove('queued', 'pending', 'ready'); b.classList.add(state); b.textContent = text;
}
var lastSent = 0;
function plural(n) { return n + (n === 1 ? ' action' : ' actions'); }
function updateBar() {
  var n = document.querySelectorAll('.queuedbadge').length, bar = document.getElementById('sendbar');
  if (!bar) return;
  var waiting = document.querySelectorAll('.sentbadge').length, btn = document.getElementById('sendbtn'), msg = document.getElementById('qmsg');
  bar.hidden = !n && !waiting;
  if (btn) btn.hidden = !n;
  if (n) { document.getElementById('qn').textContent = plural(n); msg.textContent = 'queued · they run when you send them'; }
  else { document.getElementById('qn').textContent = 'Sent ' + plural(lastSent || waiting); msg.textContent = 'waiting for the agent'; }
}
function sendQueued() {
  var q = document.querySelectorAll('.queuedbadge'), n = q.length;
  if (!n || !window.lavish) return;
  window.lavish.sendQueuedPrompts(); lastSent = n;
  for (var i = 0; i < n; i++) { q[i].className = 'sentbadge'; q[i].textContent = 'sent'; }
  updateBar();
}
function markQueued(b) {
  var row = b.closest ? b.closest('.row') : null;
  if (row && !row.querySelector('.queuedbadge')) {
    var s = document.createElement('span'); s.className = 'queuedbadge'; s.textContent = 'queued';
    row.querySelector('.rtop').appendChild(s);
  }
  updateBar();
}
function queue(a, b, label) {
  if (!window.lavish) { alert('Open this board in Lavish to run actions.'); return false; }
  window.lavish.queuePrompt(a.prompt, {tag: 'board-action', text: a.ref + ': ' + label, element: b,
    queueKey: a.ref + '|' + label + '|' + Date.now(), data: a});
  markQueued(b);
  return true;
}
function addContext(b) {
  var c = JSON.parse(b.dataset.ctx), m = document.createElement('div'); m.className = 'ctxm';
  var box = document.createElement('div'); m.appendChild(box);
  var h = document.createElement('p'); h.textContent = 'Add context to ' + c.ref; box.appendChild(h);
  var t = document.createElement('textarea'); box.appendChild(t);
  var row = document.createElement('div'); row.className = 'acts'; box.appendChild(row);
  function btn(l, f) { var x = document.createElement('button'); x.type = 'button'; x.className = 'act'; x.textContent = l; x.onclick = f; row.appendChild(x); }
  btn('Queue', function () {
    if (!t.value.trim()) return;
    var prompt = 'Add context on ' + c.ref + ' (board task ' + c.key + '): append the text below, dated, to the task; run a __KNOWLEDGE_SEARCH__ and attach the matching cards (slug and title) to the task and the row; if a colleague needs this context, draft a Linear comment or MR note in the voice of the user and show it on the row with Post/Edit/Discard, posting nothing. Text: ' + t.value;
    if (queue({ref: c.ref, label: 'Add context', text: t.value, prompt: prompt}, b, 'Add context')) { setState(b, 'pending', 'Add context · sent'); m.remove(); }
  });
  btn('Cancel', function () { m.remove(); });
  document.body.appendChild(m); t.focus();
}
function draftClick(b) {
  var box = b.closest('.ndraft'), d = JSON.parse(box.dataset.nd), t = box.querySelector('.ndt');
  if (b.classList.contains('nd-edit')) { t.readOnly = false; t.focus(); return; }
  if (b.classList.contains('nd-discard')) {
    if (queue({ref: d.ref, label: 'Discard draft', prompt: 'Discard the drafted ' + d.kind + ' on ' + d.ref + '; post nothing.'}, b, 'Discard draft')) box.remove();
    return;
  }
  if (!b.classList.contains('confirm')) { b.classList.add('confirm'); b.textContent = 'Confirm: Post'; return; }
  if (queue({ref: d.ref, label: 'Post draft', text: t.value, prompt: 'Post exactly this text as a ' + d.kind + ' on ' + d.target + ', then report the link: ' + t.value}, b, 'Post draft')) {
    b.classList.remove('confirm'); b.classList.add('queued'); b.textContent = 'Queued: Post (press Send to Agent)';
  }
}
function dboxClick(b) {
  var box = b.closest('.dbox'), d = JSON.parse(box.dataset.d), t = box.querySelector('textarea');
  if (b.classList.contains('d-discard')) {
    if (queue({ref: d.ref, label: 'Discard draft', prompt: 'Discard the drafted message ' + d.id + ' on ' + d.ref + ' (to ' + d.target + '); post nothing.'}, b, 'Discard draft')) box.remove();
    return;
  }
  if (!b.classList.contains('confirm')) { b.classList.add('confirm'); b.textContent = 'Confirm: Post'; return; }
  var label = 'Post draft ' + d.id;
  if (queue({ref: d.ref, label: label, text: t.value, prompt: 'Post exactly this text (the user edited and approved it) to ' + d.target + (d.url ? ' (' + d.url + ')' : '') +
      ' and nowhere else, then report the link and mark draft ' + d.id + ' posted on ' + d.ref + ' with board_state.py ({"drafts": [{"id": "' + d.id + '", "posted_at": "<HH:MM>"}]}): ' + t.value}, b, label)) {
    b.classList.remove('confirm'); b.classList.add('queued'); b.textContent = 'Queued: Post'; t.readOnly = true;
  }
}
document.addEventListener('click', function (e) {
  if (e.target.id === 'sendbtn') { sendQueued(); return; }
  var cb = e.target.closest('button.ctx'); if (cb) { addContext(cb); return; }
  var db = e.target.closest('.dbox button'); if (db) { if (!db.classList.contains('queued')) dboxClick(db); return; }
  var nb = e.target.closest('.ndraft button'); if (nb && !nb.classList.contains('queued')) { draftClick(nb); return; }
  var b = e.target.closest('button.act[data-act]'); if (!b || b.classList.contains('queued') || b.classList.contains('done')) return;
  var a = JSON.parse(b.dataset.act);
  var card = b.classList.contains('opt');
  if (a.outward && !b.classList.contains('confirm')) {
    b.classList.add('confirm'); b.title = a.prompt;
    if (!card) { b.dataset.orig = b.textContent; b.textContent = 'Confirm: ' + a.label; }
    return;
  }
  if (!queue(a, b, a.label)) return;
  b.classList.remove('confirm'); b.classList.add('queued');
  if (b.classList.contains('wtf')) { setState(b, 'pending', 'Wait, what? · sent'); b.classList.add('queued'); }
  else if (!card) b.textContent = b.classList.contains('dismiss') ? 'queued' : 'Queued';
});

// Live row updates: poll board-state.json (written by the agent) and patch only the listed rows.
var VERDICTS = ['close', 'notyet', 'blocked', 'hold'], lastState = '';
var ALLOWED = {A: 1, B: 1, STRONG: 1, EM: 1, I: 1, CODE: 1, BR: 1};
function cleanInto(target, html) {
  var doc = new DOMParser().parseFromString(html, 'text/html'); target.textContent = '';
  (function walk(from, to) {
    Array.prototype.forEach.call(from.childNodes, function (n) {
      if (n.nodeType === 3) { to.appendChild(document.createTextNode(n.textContent)); return; }
      if (n.nodeType !== 1) return;
      if (!ALLOWED[n.tagName]) { walk(n, to); return; }
      var c = document.createElement(n.tagName);
      if (n.tagName === 'A' && /^https:[/][/]/.test(n.getAttribute('href') || '')) {
        c.href = n.getAttribute('href'); c.target = '_blank'; c.rel = 'noopener';
      }
      walk(n, c); to.appendChild(c);
    });
  })(doc.body, target);
}
function patchProgress(tr, p) {
  var box = tr.querySelector('.prog');
  if (!box) { box = document.createElement('div'); box.className = 'prog'; var anchor = tr.querySelector('.ctxd'); anchor.parentNode.insertBefore(box, anchor); }
  box.textContent = '';
  var ul = document.createElement('ul'); box.appendChild(ul);
  (Array.isArray(p.done) ? p.done : []).forEach(function (d) {
    var li = document.createElement('li'); li.textContent = String(d.text || '') + ' ';
    var sm = document.createElement('small'); sm.textContent = String(d.at || ''); li.appendChild(sm); ul.appendChild(li);
  });
  if (p.pending) {
    var pd = document.createElement('div'); pd.className = 'pend';
    pd.textContent = 'Still open: ' + p.pending + (p.owner ? ' (' + p.owner + ')' : ''); box.appendChild(pd);
  }
}
function patchCards(tr, list) {
  var box = tr.querySelector('.cards') || tr.querySelector('.nx').parentNode.appendChild(document.createElement('div'));
  box.className = 'cards'; box.textContent = 'Brain: ';
  list.forEach(function (c, i) {
    if (i) box.appendChild(document.createTextNode(', '));
    var el = document.createElement(/^https:[/][/]/.test(c.url || '') ? 'a' : 'span');
    if (el.tagName === 'A') { el.href = c.url; el.target = '_blank'; el.rel = 'noopener'; }
    el.textContent = String(c.title || c.slug); box.appendChild(el);
  });
}
function patchDecided(tr, d) {
  var old = tr.querySelector('.decision') || tr.querySelector('.dptr') || tr.querySelector('.decided');
  var line = document.createElement('div'); line.className = 'decided';
  line.textContent = 'Decided: ' + String(d.option || '') + (d.at ? ' · ' + d.at : '');
  if (old) { old.parentNode.insertBefore(line, old); old.remove(); }
  else { var a = tr.querySelector('.ctxd'); a.parentNode.insertBefore(line, a); }
  if (String(tr.id || '').indexOf('row-d-') === 0) tr.hidden = true;
}
function patchExplained(tr, e) {
  var old = tr.querySelector('.explained'); if (old) old.remove();
  if (!e || typeof e !== 'object' || !e.text) return;
  var box = document.createElement('div'); box.className = 'explained';
  var h = document.createElement('b'); h.textContent = 'In plain English' + (e.at ? ' ' + e.at : ''); box.appendChild(h);
  var t = document.createElement('div'); t.className = 'etext'; t.textContent = String(e.text); box.appendChild(t);
  var anchor = tr.querySelector('.ctxd'); anchor.parentNode.insertBefore(box, anchor);
  setState(tr.querySelector('button.wtf'), 'ready', 'Wait, what? · explained');
}
function patchDraft(tr, id, d) {
  var old = tr.querySelector('.ndraft'); if (old) old.remove();
  var first = tr.querySelector('button.act[data-act]'), ref = first ? JSON.parse(first.dataset.act).ref : id;
  var box = document.createElement('div'); box.className = 'ndraft';
  box.dataset.nd = JSON.stringify({ref: ref, kind: String(d.kind || 'note'), target: String(d.target || '')});
  var h = document.createElement('div'); h.className = 'ndh'; h.textContent = 'Draft ' + (d.kind || 'note') + ' to ' + (d.target || '') + ' (not posted)'; box.appendChild(h);
  var t = document.createElement('textarea'); t.className = 'ndt'; t.readOnly = true; t.value = String(d.text || ''); box.appendChild(t);
  var row = document.createElement('div'); row.className = 'acts'; box.appendChild(row);
  [['Post', 'act outward nd-post'], ['Edit', 'act nd-edit'], ['Discard', 'act nd-discard']].forEach(function (p) {
    var x = document.createElement('button'); x.type = 'button'; x.className = p[1]; x.textContent = p[0]; row.appendChild(x);
  });
  var rb = tr.querySelector('.rbody'), bar = rb.querySelector(':scope > .acts'); rb.insertBefore(box, bar);
}
function markPosted(box, at) {
  box.classList.add('posted'); box.querySelector('.dstate').textContent = 'Posted at ' + at;
  var a = box.querySelector('.dacts'); if (a) a.remove();
  box.querySelector('textarea').readOnly = true;
}
function patchDrafts(tr, list) {
  list.forEach(function (d) {
    if (!d || !d.id) return;
    var box = tr.querySelector('.dbox[data-did="' + String(d.id).replace(/"/g, '') + '"]');
    if (!box) return;
    if (d.discarded) box.remove(); else if (d.posted_at) markPosted(box, String(d.posted_at));
  });
}
function patchRow(id, s) {
  var tr = document.getElementById(id); if (!tr || !s) return;
  var pill = tr.querySelector('.vc .pill'), stripe = tr.querySelector('.stripe');
  if (pill && VERDICTS.indexOf(s.verdict) >= 0) { pill.className = 'pill ' + s.verdict; if (stripe) stripe.className = 'stripe ' + s.verdict; }
  if (pill && typeof s.label === 'string') pill.textContent = s.label;
  if (VERDICTS.indexOf(s.verdict) >= 0) {
    var ks = chipKeys(tr).filter(function (k) { return k !== 'act-now' && k !== 'waiting-on-others'; });
    if (s.verdict === 'close') ks.push('act-now'); if (s.verdict === 'hold') ks.push('waiting-on-others');
    tr.setAttribute('data-chips', ks.join(' '));
  }
  var nx = tr.querySelector('.nx'), why = tr.querySelector('.why');
  if (nx && typeof s.next === 'string') { cleanInto(nx, s.next); if (why && typeof s.why !== 'string') why.textContent = nx.textContent.split(/(?<=[.!?])\\s/)[0].slice(0, 140); }
  if (why && typeof s.why === 'string') why.textContent = s.why;
  var qb = tr.querySelector('.queuedbadge'), sb = tr.querySelector('.sentbadge'); if (qb) qb.remove(); if (sb) sb.remove(); updateBar();
  if (s.progress && typeof s.progress === 'object') patchProgress(tr, s.progress);
  if (Array.isArray(s.cards)) patchCards(tr, s.cards);
  if ((Array.isArray(s.cards) && s.cards.length) || s.context_saved) setState(tr.querySelector('button.ctx'), 'ready', 'Add context · saved');
  if (s.explained) patchExplained(tr, s.explained);
  if (Array.isArray(s.drafts)) patchDrafts(tr, s.drafts);
  if (s.decided && typeof s.decided === 'object') {
    patchDecided(tr, s.decided);
    var ptrs = document.querySelectorAll('.dptr[data-dref="' + id + '"]');  // one patch resolves the decision on every card it blocks
    for (var pi = 0; pi < ptrs.length; pi++) { var pr = ptrs[pi].closest('.row'); if (pr) patchDecided(pr, s.decided); }
  }
  if (s.note_draft && typeof s.note_draft === 'object') patchDraft(tr, id, s.note_draft);
  (Array.isArray(s.done_actions) ? s.done_actions : []).forEach(function (l) {
    tr.querySelectorAll('button.act[data-act]').forEach(function (b) {
      if (JSON.parse(b.dataset.act).label === l) { b.classList.remove('confirm', 'queued'); b.classList.add('done'); if (!b.classList.contains('opt')) b.textContent = b.classList.contains('dismiss') ? 'dismissed' : 'Done: ' + l; }
    });
  });
}
// The Lavish iframe is sandboxed without allow-same-origin, so a fetch of board-state.json is a cross-origin
// request the artifact server never answers with CORS headers: it always fails. A script tag is not subject to
// CORS, so board-state.js (window.boardState = {...}, written by board_state.py) is the working transport;
// the fetch stays as a fallback for a same-origin host.
function applyState(t) {
  var rows;
  try { rows = (typeof t === 'string' ? JSON.parse(t) : t).rows || {}; } catch (e) { return; }
  var key = JSON.stringify(rows);
  if (key === lastState) return;
  var ok = true;
  Object.keys(rows).forEach(function (id) {
    try { patchRow(id, rows[id]); } catch (e) { ok = false; if (window.console) console.error('board-state row ' + id + ': ' + e); }
  });
  if (typeof applyChipFilter === 'function') applyChipFilter();
  if (ok) lastState = key;
}
function pollState() {
  fetch('board-state.json?t=' + Date.now(), {cache: 'no-store'}).then(function (r) { return r.ok ? r.text() : ''; })
    .then(function (t) { if (t) applyState(t); }).catch(function () {});
  try {
    var sc = document.createElement('script');
    sc.src = 'board-state.js?t=' + Date.now();
    sc.onload = function () { sc.remove(); if (window.boardState) applyState(window.boardState); };
    sc.onerror = function () { sc.remove(); };
    (document.head || document.documentElement).appendChild(sc);
  } catch (e) {}
}
setInterval(pollState, 5000); pollState();
</script>
"""


def slug(kind, text):
    return f"row-{kind}-" + re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def progress(x):
    p = x.get("progress")
    if not p:
        return ""
    done = "".join(f'<li>{html.escape(d.get("text", ""))} <small>{html.escape(d.get("at", ""))}</small></li>'
                   for d in p.get("done", []))
    pend = html.escape(p.get("pending", ""))
    who = html.escape(p.get("owner", ""))
    todo = f'<div class="pend">Still open: {pend}' + (f' <small>({who})</small>' if who else "") + "</div>" if pend else ""
    return f'<div class="prog"><ul>{done}</ul>{todo}</div>'


def check_actions(rows, user):
    bad = [ref for x, ref in rows if not real_actions(x, ref, user) and not (x.get("_dptr") and not x.get("decided"))]
    if bad:
        raise ValueError("row without a real action besides Nevermind (a nudge to the user themself does "
                         "not count; drop finished rows instead): " + ", ".join(bad))


GENERIC = {"not yet", "waiting", "hold", "blocked", "close", "on hold"}


def check_labels(rows):
    bad = [ref for x, ref in rows if (x.get("progress") or {}).get("pending") and x["label"].strip().lower() in GENERIC]
    if bad:
        raise ValueError("generic label on a row with one step left (name the step, e.g. 'Only the production "
                         "apply left'): " + ", ".join(bad))


def check_ids(rows):
    seen = set()
    for r in rows:
        if r in seen:
            raise ValueError(f"duplicate row id {r!r}: two rows would share one board-state entry")
        seen.add(r)


def norm(ref, kind=None):
    """Canonical row identity; tickets (PI-1903) and MRs (pi !1903) never collide."""
    flat = re.sub(r"\s+", "", re.sub(r"\s*!", "-", ref.strip()))
    kind = kind or ("t" if re.fullmatch(r"[A-Z]+-\d+", flat) else
                    "mr" if "!" in ref or re.fullmatch(r"[a-z-]+-\d+", flat) else "o")
    return kind + ":" + flat.lower()


def drop_abandoned(b):
    """Drop rows whose task is abandoned unless their 'updated' date is later. Entries match by task key
    (exact) or, without a key, by raw ref."""
    by_key = {d["key"].lower(): d["date"] for d in b.get("abandoned", []) if d.get("key")}
    by_ref = {norm(d["ref"]): d["date"] for d in b.get("abandoned", []) if not d.get("key")}

    def keep(x, refs, kind=None):
        found = [by_key[k] for k in (task_key(x), x["id"].lower() if "id" in x else "") if k in by_key]
        found += [by_ref[norm(r, kind)] for r in refs if norm(r, kind) in by_ref]
        return not found or str(x.get("updated", "")) > max(found)
    b["tickets"] = [x for x in b["tickets"] if keep(x, [x["id"]], "t")]
    b["mrs"] = [x for x in b["mrs"] if keep(x, [r[1] for r in x["refs"]], "mr")]
    b["decisions"] = [x for x in b.get("decisions", []) if keep(x, [x["id"]])]
    b["buddy"] = [x for x in b.get("buddy", []) if keep(x, [x["id"]])]


HOME_DIR = "LINEAR_ACTION_BOARD_HOME"


def answered_records(b):
    """Answered decisions that outlive a rebuild: board.json `answered` plus the durable decided.json that board_state.py appends to."""
    home = Path(os.environ.get(HOME_DIR) or "~/.config/linear-action-board").expanduser()
    try:
        durable = json.loads((home / "decided.json").read_text())
    except (OSError, ValueError):
        durable = []
    return list(b.get("answered", [])) + (durable if isinstance(durable, list) else [])


def apply_answered(b):
    """A row whose decision was answered stays answered across rebuilds, unless the row changed after the answer."""
    by_key = {}
    for d in answered_records(b):
        if isinstance(d, dict) and d.get("key") and d.get("option"):
            by_key[d["key"].lower()] = d
    for x in b["tickets"] + b["mrs"] + b.get("decisions", []):
        if not (x.get("decision") or x.get("decision_ref")) or x.get("decided"):
            continue
        d = by_key.get(task_key(x))
        if d and str(x.get("updated", "")) <= str(d.get("date", "")):
            x["decided"] = {"option": d["option"], "at": d.get("date", "")}


def lift_action_drafts(rows):
    """A draft named only inside an action is lifted onto the row so the card always shows it; an unreadable one aborts."""
    for x, ref in rows:
        for a in x.get("actions") or []:
            if not (a.get("draft") or a.get("draft_file")):
                continue
            if not (x.get("draft") or x.get("draft_file")):
                for k in ("draft", "draft_file"):
                    if a.get(k):
                        x[k] = a[k]
            if draft_text(a) is None:
                raise ValueError(f"action {a['label']!r} on {ref} names a draft that cannot be read ({a.get('draft_file')}): "
                                 "put a readable `draft_file` or the text in `draft` so the card can show it")


def main(src, out=None, tasks_out=None, extra_decisions=None, collect=None, feed_out=None, holds_cmd=None, actions_out=None):
    b = json.loads(Path(src).read_text())
    if extra_decisions:
        b["decisions"] = b.get("decisions", []) + json.loads(Path(extra_decisions).read_text())
    b["buddy"] = []
    for x in b.pop("buddy_tasks", []):
        if x["key"].startswith("board-"):
            continue  # the board's own tasks are never shown back as rows
        b["buddy"].append(dict(x, id="buddy-" + x["key"], _task_key=valid_key(x["key"])))
    for x in b.get("decisions", []) + b["buddy"]:
        x.setdefault("_kind", "d")
        x.setdefault("verdict", "notyet")
        x.setdefault("label", "Decision needed")
        x.setdefault("status", "Open")
        x.setdefault("next", "")
    STATE_COLORS.clear()
    STATE_COLORS.update(b.get("state_colors", {}))
    apply_answered(b)
    b["decisions"] = [x for x in b.get("decisions", []) if not x.get("decided")]  # a landed standalone decision is gone
    drop_abandoned(b)
    head = TEMPLATE.read_text().split('<div class="wrap">')[0]
    t = b["tickets"]
    m = b["mrs"]
    dec = b.get("decisions", [])
    bud = b["buddy"]
    user = b.get("user", "")
    closed = merged_rows(b, user)
    m = b["mrs"]
    apply_facts(m, load_facts(b, src, collect), user)
    lift_review(m, user, b.get("review_reports"))
    add_steps(m, user)
    every = [(x, x["id"]) for x in t + dec + bud] + [(x, x["refs"][0][1]) for x in m]
    add_merge(m, user)
    inherit_buttons(t, m, user)
    lift_action_drafts(every)
    ids = {x["refs"][0][1]: slug("mr", x["refs"][0][1]) for x in m}
    ids.update({x["id"]: slug(k, x["id"]) for k, rs in (("t", t), ("d", dec), ("b", bud)) for x in rs})
    share_decisions(every, ids)
    for x, ref in every:
        if x.get("decision") and not x.get("decided"):
            check_decision(x, ref)
            check_outward_draft(x, ref)
    for x, ref in every:
        check_drafts(x, ref)
    check_standalone(dec, t, m)
    check_actions(every, user)
    check_labels(every)
    check_ids([slug("t", x["id"]) for x in t] + [slug("mr", x["refs"][0][1]) for x in m] + [slug("d", x["id"]) for x in dec] + [slug("b", x["id"]) for x in bud])
    tag_rows(t, m, dec + bud)
    if feed_out:
        holds = feed.load_holds(holds_cmd or os.environ.get("COMPANION_HOLDS_CMD"))
        feed_doc, sidecar = feed.build(sys.modules[__name__], b, t, m, dec, user, holds)
        feed.write(feed_out, feed_doc, sidecar, actions_out)
        print(f"wrote {feed_out}: {len(feed_doc['decisions'])} decisions, {len(feed_doc['mrs'])} MRs, {len(feed_doc['tickets'])} tickets")

    def ticket_row(x):
        title = f' <span class="ttl">{html.escape(x.get("title") or x["what"])}</span>'
        return row_html(x, slug("t", x["id"]), x["id"],
                        link(org.LINEAR_ISSUE_BASE + x["id"], x["id"]) + title,
                        user, with_track=True)

    def mr_row(x):
        ref = x["refs"][0][1]
        return row_html(x, slug("mr", ref), ref, ref_lines(x["refs"], x.get("title") or x["what"]), user, f'Author: {html.escape(x["author"])}')

    def plain_row(x, kind):
        return row_html(x, slug(kind, x["id"]), x["id"], html.escape(x["id"]), user, f'Status: {html.escape(x["status"])}')

    def section(title, rows, kind, lede):
        if not rows:
            return ""
        return (f'<section><h2>{title}</h2><p class="lede">{autolink(lede)}</p>'
                + lanes([(x, plain_row(x, kind)) for x in rows], user) + "</section>")

    def is_reviewer(x):
        if x.get("role"):
            return x["role"] == "reviewer"
        return x["author"].lower() not in SELF | {user.lower()}

    tsec = lanes([(x, ticket_row(x)) for x in t], user, key=lambda x: -stage_index(x))
    mine = lanes([(x, mr_row(x)) for x in m if not is_reviewer(x)], user)
    revw = lanes([(x, mr_row(x)) for x in m if is_reviewer(x)], user)
    msec = (f'<div class="fg"><h3>My MRs</h3>{mine}</div>' if mine else "") + (f'<div class="fg"><h3>Reviewing</h3>{revw}</div>' if revw else "")
    dsec = section("Decisions", dec, "d", b.get("decisions_lede", "Decisions with no ticket or MR behind them."))
    bsec = section("Buddy tasks", bud, "b", b.get("buddy_lede", "Open tasks held by your Brain buddy, not tracked in Linear."))
    chip_html = chip_bar(t, m, dec + bud, b.get("chips", {}))
    d = html.escape(b["date"])
    banner = (f'<div class="banner">Brain sync skipped: {html.escape(b["sync_error"])}. '
              'Rows were not recorded as board tasks this build.</div>') if b.get("sync_error") else ""
    if tasks_out:  # buddy rows already are tasks; a merged row's task says what is not confirmed, a closed one is done
        rows_tm = {id(y) for y in t + m}
        merged_for = {y["ticket"]: y for y in m if y.get("_ship") and y.get("ticket")}
        Path(tasks_out).write_text(json.dumps([{"key": task_key(x), "status": task_status(x, user), "title": x.get("what", "")}
                                               | ({"delivery": delivery(x, b["date"], merged_for)} if id(x) in rows_tm else {})
                                               | ({"content": f"merged, {x['_ship']} not confirmed"} if x.get("_ship") else {})
                                               for x in dec + t + m] + [
            {"key": task_key(x), "status": "done", "title": x.get("what", ""), "delivery": delivery(x, b["date"]),
             "content": f"left the board: {x['_closed']}"} for x in closed], indent=1))
    for x in closed:
        print(f"dropped {x['refs'][0][1]}: {x['_closed']}; set its board task {task_key(x)} done")
    body = f'''<div class="wrap">{banner}
<header>
  <h1>Linear Action Board</h1>
  <p>Your open Linear tickets and the merge requests waiting on someone. Snapshot of {d}; states move, re-check before acting.</p>
</header>
<div class="summary">
{chip_html}
</div>
{dsec}
<section>
  <h2>Linear tickets</h2>
  <p class="lede">{autolink(b.get("tickets_lede", ""))}</p>
  {tsec}
</section>
<section>
  <h2>Merge requests: approvals and replies</h2>
  <p class="lede">{autolink(b.get("mrs_lede", ""))}</p>
  {msec}
</section>
{bsec}
<div class="note">Reading the pills: <span class="pill close">green</span> you can act now · <span class="pill notyet">amber</span> one step owed · <span class="pill blocked">red</span> risk if merged as is · <span class="pill hold">blue</span> waiting on someone else.</div>
{"<div class='note'>Buttons queue a request to Claude; send them with the bar at the bottom (or Send to Agent in the Lavish bar). Dashed buttons act outward (post, approve, Slack) and need a second confirm click.</div><div id='sendbar' hidden><span><b id='qn'>0 actions</b> <span id='qmsg'>queued · they run when you send them</span></span><button type='button' class='act primary' id='sendbtn'>Send to agent</button></div>" if LAVISH else ""}
<footer>Sources: Linear (assigned to you), GitLab approvals and discussions via glab, read-only checks. Snapshot {d}.</footer>
</div>
'''
    if out:
        Path(out).write_text(head + body + FILTER_JS + (LAVISH_JS.replace("__KNOWLEDGE_SEARCH__", json.dumps(org.KNOWLEDGE_SEARCH)[1:-1].replace("'", "\\'")) if LAVISH else ""))
        print(f"wrote {out}: {len(t)} tickets, {len(m)} MR rows")


if __name__ == "__main__":
    LAVISH = "--lavish" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--lavish"]
    opts = {}
    for flag in ("--tasks", "--decisions", "--collect", "--feed", "--holds-cmd", "--actions-out"):
        if flag in args:
            i = args.index(flag)
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    main(*args[:2], tasks_out=opts.get("--tasks"), extra_decisions=opts.get("--decisions"), collect=opts.get("--collect"),
         feed_out=opts.get("--feed"), holds_cmd=opts.get("--holds-cmd"), actions_out=opts.get("--actions-out"))
