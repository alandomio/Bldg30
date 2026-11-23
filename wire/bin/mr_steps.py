"""MR facts to board buttons: the step an MR row names, the merge_state it implies, and review drafts to lift.

Pure helpers shared by collect_mrs.py (adds `step` and `merge_state` to its facts) and render.py
(gives every row a first button that performs the step, and lifts review drafts onto cards).
"""
import os, re
from datetime import datetime, timezone
from pathlib import Path

# Statuses where the only thing between the MR and the merge button is what merge_state itself checks.
MERGEABLE_STATUSES = {"mergeable", "discussions_not_resolved"}
CONFLICT_STATUSES = {"conflict", "need_rebase"}

STEPS = {
    "rebase": "Rebase it",
    "rework": "Rework it",
    "fix_pipeline": "Fix the pipeline",
    "fix_threads": "Fix the threads",
    "check_threads": "Check the threads",
    "review": "Start review",
}


def _ts(s):
    """ISO timestamp (GitLab, with Z or an offset) to an aware datetime, or None."""
    if not s:
        return None
    try:
        d = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def owed_threads(f):
    """Open threads whose next move is the MR author's."""
    return [t for t in f.get("open_threads") or [] if t.get("next_move") == "author"]


def merge_state(f):
    """The row's merge_state from collect facts, or None when the MR cannot be merged by its author now
    (not open, draft, changes requested, unknown merge status, unknown pipeline). The facts may still
    fail a condition (red pipeline, no approval); render.py's merge_ready decides whether Merge shows."""
    hp = f.get("head_pipeline") or {}
    status = f.get("merge_status")
    if f.get("state") != "opened" or f.get("draft") or not hp.get("status"):
        return None
    if status not in MERGEABLE_STATUSES | CONFLICT_STATUSES:
        return None
    approvers = f.get("approved_by") or []
    required = f.get("approvals_required")
    approved = bool(approvers) and len(approvers) >= (required or 1)  # no approval needed is not an approval: set "not_required" by hand
    ms = {"conflicts": status in CONFLICT_STATUSES, "pipeline": hp["status"], "approved": approved,
          "open_threads": len(f.get("open_threads") or [])}
    if hp.get("sha_matches_head"):
        ms["pipeline_on_head"] = True
    else:  # a merge-result project: the run is for the merge commit, current when it began after the last push
        made, pushed = _ts(hp.get("created_at")), _ts(f.get("last_commit_at"))
        ms.update(pipeline_scope="merge_result", merge_result_current=bool(made and pushed and made >= pushed))
    return ms


def step(f, own):
    """The one step the MR's state names for the user, or None when nothing is actionable.
    own: the user authored it (code steps), else the user reviews it (review step)."""
    if f.get("state") != "opened" or f.get("draft"):
        return None
    if not own:
        if f.get("user_approved"):
            return None
        if not f.get("user_last_comment_at") or f.get("commit_after_user_comment"):
            return "review"
        return None
    status = f.get("merge_status")
    if status in CONFLICT_STATUSES:
        return "rebase"
    if status == "requested_changes":
        return "rework"
    if (f.get("head_pipeline") or {}).get("status") == "failed":
        return "fix_pipeline"
    return "fix_threads" if owed_threads(f) else None


LABEL_STEPS = [
    ("rebase", re.compile(r"rebase|conflict", re.I)),
    ("rework", re.compile(r"changes requested|rework", re.I)),
    ("fix_pipeline", re.compile(r"pipeline (failed|is failing|is red)|failing pipeline|fix the pipeline", re.I)),
    ("check_threads", re.compile(r"^check\b.*\bthreads?\b", re.I)),
    ("fix_threads", re.compile(r"^(answer|address|fix|reply to)\b.*\bthreads?\b", re.I)),
    ("review", re.compile(r"review owed|start (re-)?review|^review\b", re.I)),
]


def step_from_label(label, own):
    """Fallback for a row without facts: the step its own label names (code steps on own MRs, review on others)."""
    for name, pat in LABEL_STEPS:
        if pat.search(label or "") and (name == "review") != own:
            return name
    return None


def step_prompt(name, url, fact=None):
    """The exact instruction behind a step button. Everything is prepared locally; nothing is posted."""
    if name == "rebase":
        return (f"Rebase {url} onto the current target branch in a separate worktree of its branch: resolve conflicts keeping "
                "the target's changes, run the project's validation, push the branch with --force-with-lease and report "
                "the new head SHA. Post nothing.")
    if name == "rework":
        return (f"Read the requested changes on {url} (every review note and open thread), implement them on the MR branch in a "
                "separate worktree, run the project's validation and push. Draft any reply in the user's voice, one per "
                "thread, and show them; post nothing.")
    if name == "fix_pipeline":
        return (f"Find the failing job of the latest pipeline on {url}, read its log, fix the cause on the MR branch in a "
                "separate worktree, run the project's validation and push. Report the cause and the fix. Post nothing.")
    if name == "fix_threads":
        return (f"Address every open thread on {url} that waits on the author (human and bot): apply what is right in a "
                "separate worktree of the MR branch, run the project's validation and push, then draft one reply per thread "
                "in the user's voice and show them. Resolve and post nothing.")
    if name == "check_threads":
        return (f"Final feedback check on {url}: read every open thread live, human and bot, and give each a verdict: actioned, "
                "not actionable, or needs work (a human question nobody answered always needs work). Report the verdicts in chat "
                "and on this row; resolve, merge and post nothing.")
    return (f"Run the mr-review skill on {url}"
            + (", focused on what changed since the user's last comment" if (fact or {}).get("commit_after_user_comment") else "")
            + ". Report only; never approve, never post.")


def mr_ticket_ids(row):
    """Ticket ids an MR row names: its `ticket` and any [IN-1234] in its titles."""
    text = " ".join([str(row.get("ticket") or ""), str(row.get("title") or ""), str(row.get("what") or "")]
                    + [r[2] for r in row["refs"] if len(r) > 2])
    return {m.upper() for m in re.findall(r"\b[A-Za-z]{2,5}-\d+\b", text)}


def step_action(name, url, fact=None):
    return {"label": STEPS[name], "outward": False, "prompt": step_prompt(name, url, fact)}


# ---- review reports: draft boxes and Approve -------------------------------------------------

DRAFT_SECTION = re.compile(r"^## [^\n]*(?:[Dd]raft|[Cc]omment)[^\n]*\n(.*?)(?=^## |\Z)", re.S | re.M)
NOISE = re.compile(r"^(File:|Saved as|Placement:|General MR note|Single general comment|Same text|Text:|---|\s*$)")
VERDICT_SECTION = re.compile(r"^## Verdict[^\n]*\n(.*?)(?=^## |\Z)", re.S | re.M)


def _clean(body):
    lines = [l[2:] if l.startswith("> ") else l[1:] if l.startswith(">") else l for l in body.strip().splitlines()]
    text = "\n".join(lines).strip().strip("`").strip().splitlines()
    while text and (NOISE.match(text[0]) or text[0].strip().endswith("Text:")):
        text = text[1:]
    return "\n".join(text).strip()


def report_drafts(report_dir):
    """[(title, text)] drafted for the MR: comment-draft.md if present, else the report's draft section
    (one draft per `### ` heading inside it, else the whole section)."""
    d = Path(report_dir).expanduser()
    cd = d / "comment-draft.md"
    if cd.is_file():
        text = cd.read_text().strip()
        return [("Comment", text)] if text else []
    try:
        report = (d / "report.md").read_text()
    except OSError:
        return []
    m = DRAFT_SECTION.search(report)
    if not m:
        return []
    parts = re.split(r"^### ([^\n]*)\n", m.group(1), flags=re.M)
    pairs = [(parts[i].strip(), parts[i + 1]) for i in range(1, len(parts), 2)] if len(parts) > 1 else [("Comment", m.group(1))]
    return [(t, c) for t, c in ((t, _clean(b)) for t, b in pairs) if c]


def report_safe_to_approve(report_dir):
    """True when the report's Verdict section opens with 'Safe to approve' or 'Approve' ('Not ready' and anything else is False)."""
    try:
        report = (Path(report_dir).expanduser() / "report.md").read_text()
    except OSError:
        return False
    m = VERDICT_SECTION.search(report)
    first = next((l for l in (m.group(1).splitlines() if m else []) if l.strip()), "")
    return bool(re.match(r"\W*(safe to approve|approve)\b", first, re.I))


def report_dir(row, template=None):
    """The review report folder for a row: its own `review` (a folder or its report.md), else `template` with
    {ref} (pi-1929), {short} (pi) and {iid} (1929) filled from the row's first ref ('pi !1929'), else the
    LINEAR_ACTION_BOARD_REVIEWS env var as that template. None when not configured or not on disk."""
    own = row.get("review")
    template = template or os.environ.get("LINEAR_ACTION_BOARD_REVIEWS")
    if own:
        p = Path(own).expanduser()
        path = p.parent if p.name.endswith(".md") else p
    else:
        m = re.match(r"([\w/-]+)\s?!(\d+)", row["refs"][0][1])
        if not (template and m):
            return None
        short = m.group(1).split("/")[-1]
        path = Path(template.format(ref=f"{short}-{m.group(2)}", short=short, iid=m.group(2))).expanduser()
    return path if path.is_dir() else None
