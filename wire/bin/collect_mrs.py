#!/usr/bin/env python3
"""Collect live GitLab facts for the Linear Action Board.

Reads every open non-draft MR authored by or assigned for review to USER,
plus any extra MR refs given (project_id!iid), and prints TOON (or JSON).
Facts only, no verdicts: the model decides verdicts and next actions. `step` (the action the state names) and
`merge_state` (for render.py's Merge button) are derived from those facts by mr_steps.py.

With --merged-since YYYY-MM-DD it also reads the user's own MRs merged since then in projects where nothing
ships on merge (the 'ships' key of the org config): the candidates for the board's "Merged, apply/release not confirmed" rows.

Usage: collect_mrs.py [--user <gitlab username, default: the glab-authenticated user>] [--extra 34967520!1834 ...] [--merged-since 2026-10-12] [--format toon|json]  (TOON default)
"""
import argparse, json, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import mr_steps
import org


def api(path):
    try:  # a dead socket after laptop sleep otherwise hangs the whole feed job
        out = subprocess.run(["glab", "api", path], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"glab api {path}: no answer in 60 s")
    if out.returncode != 0:
        raise RuntimeError(f"glab api {path}: {out.stderr.strip()[:200]}")
    # glab output can carry control characters that break json.loads
    return json.loads("".join(c for c in out.stdout if c >= " " or c in "\n\t"))


def list_mrs(user):
    refs = {}
    for key in ("author_username", "reviewer_username"):
        for mr in api(f"merge_requests?{key}={user}&state=opened&scope=all&per_page=100"):
            if not mr.get("draft"):
                refs[f"{mr['project_id']}!{mr['iid']}"] = key.split("_")[0]
    return refs


def shipping_merged(mrs, since, ships):
    """Refs of MRs merged into main (merged_at on or after `since`) whose project needs a production apply or release.
    An MR merged into another branch ships nothing by itself, so it is skipped."""
    projects = set(ships.get("apply", [])) | set(ships.get("release", []))
    refs = {}
    for mr in mrs:
        path = mr["references"]["full"].split("!")[0]
        path = path[len(org.GITLAB_GROUP + "/"):] if path.startswith(org.GITLAB_GROUP + "/") else path
        if path in projects and mr.get("target_branch") in ("main", "master") and (mr.get("merged_at") or "")[:10] >= since:
            refs[f"{mr['project_id']}!{mr['iid']}"] = "merged"
    return refs


def list_merged(user, since):
    mrs = api(f"merge_requests?author_username={user}&state=merged&scope=all&updated_after={since}T00:00:00Z&per_page=100")
    return shipping_merged(mrs, since, org.SHIPS)


def facts(ref, role, user):
    pid, iid = ref.split("!")
    base = f"projects/{pid}/merge_requests/{iid}"
    mr = api(base)
    try:
        appr = api(f"{base}/approvals")
    except RuntimeError:
        appr = {}
    discussions = api(f"{base}/discussions?per_page=100")
    notes = [n for d in discussions for n in d["notes"] if not n.get("system")]
    commits = api(f"{base}/commits?per_page=1")
    last_commit = commits[0]["created_at"] if commits else None

    open_threads = []
    for d in discussions:
        first = d["notes"][0]
        if not first.get("resolvable") or first.get("resolved"):
            continue
        last = d["notes"][-1]["author"]["username"]
        open_threads.append({
            "opened_by": first["author"]["username"],
            "last_by": last,
            "next_move": "author" if last != mr["author"]["username"] else "reviewer",
            "excerpt": first["body"][:90].replace("\n", " "),
        })

    user_notes = [n["created_at"] for n in notes if n["author"]["username"] == user]
    user_last = max(user_notes) if user_notes else None
    other_notes = [n for n in notes if n["author"]["username"] not in (user, "pp-code-review-bot")]
    hp = mr.get("head_pipeline") or {}
    fact = {
        "ref": ref,
        "url": mr["web_url"],
        "project": mr["references"]["full"].split("!")[0].split("/")[-1],
        "iid": mr["iid"],
        "title": mr["title"],
        "author": mr["author"]["username"],
        "role": role,
        "state": mr["state"],
        "draft": mr["draft"],
        "merged_at": mr.get("merged_at"),
        "merge_status": mr.get("detailed_merge_status"),
        "target_branch": mr["target_branch"],
        "approved_by": [a["user"]["username"] for a in appr.get("approved_by", [])],
        "approvals_required": appr.get("approvals_required"),
        "open_threads": open_threads,
        "user_last_comment_at": user_last,
        "last_commit_at": last_commit,
        "commit_after_user_comment": bool(user_last and last_commit and last_commit > user_last),
        "last_other_note_at": max((n["created_at"] for n in other_notes), default=None),
        "head_pipeline": {"status": hp.get("status"), "sha_matches_head": hp.get("sha") == mr.get("sha"),
                          "created_at": hp.get("created_at")},
        "user_approved": user in [a["user"]["username"] for a in appr.get("approved_by", [])],
    }
    own = mr["author"]["username"] == user
    fact["step"] = mr_steps.step(fact, own) if own or role == "reviewer" else None
    fact["merge_state"] = mr_steps.merge_state(fact) if own else None
    return fact


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default=None)
    ap.add_argument("--extra", nargs="*", default=[], help="project_id!iid, e.g. MRs from the previous board")
    ap.add_argument("--merged-since", default=None, help="YYYY-MM-DD: also the user's MRs merged since then where nothing ships on merge")
    ap.add_argument("--format", choices=["toon", "json"], default="toon")
    a = ap.parse_args()
    a.user = a.user or api("user")["username"]
    refs = list_mrs(a.user)
    if a.merged_since:
        refs.update({r: k for r, k in list_merged(a.user, a.merged_since).items() if r not in refs})
    for r in a.extra:
        refs.setdefault(r, "extra")
    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(lambda kv: _safe(kv, a.user), refs.items()))
    if a.format == "json":
        json.dump({"user": a.user, "mrs": results}, sys.stdout, indent=1)
    else:
        print(to_toon(a.user, results))


MR_FIELDS = ["ref", "project", "iid", "title", "author", "role", "state", "merged_at", "merge_status", "target_branch",
             "approved_by", "approvals_required", "open_threads", "user_last_comment_at",
             "commit_after_user_comment", "last_other_note_at", "pipeline", "step", "url"]
BOTS = {"pp-code-review-bot"}
THREAD_FIELDS = ["ref", "opened_by", "last_by", "next_move", "excerpt"]


def _cell(v):
    # TOON scalar: bare unless it needs quoting
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list):
        v = "|".join(map(str, v))
    s = str(v)
    if len(s) >= 20 and s[4] == "-" and s[10] == "T":  # ISO timestamp -> minutes, UTC
        s = s[:16].replace("T", " ")
    if s == "" or any(c in s for c in ',"\n:') or s != s.strip():
        return '"' + s.replace('"', '\\"').replace("\n", " ") + '"'
    return s


def to_toon(user, results):
    ok = [r for r in results if "error" not in r]
    bad = [r for r in results if "error" in r]
    lines = [f"user: {user}", f"mrs[{len(ok)}]{{{','.join(MR_FIELDS)}}}:"]
    threads = []
    for r in ok:
        r = dict(r, open_threads=len(r["open_threads"]),
                 pipeline=f"{r['head_pipeline']['status']}{'' if r['head_pipeline']['sha_matches_head'] else '(not-head)'}",
                 url=r["url"].replace(org.GITLAB_BASE, ""))
        lines.append("  " + ",".join(_cell(r.get(f)) for f in MR_FIELDS))
    bots = 0
    for r in ok:
        for t in r["open_threads"]:
            if t["opened_by"] in BOTS:  # bot findings: counted, not listed
                bots += 1
                continue
            threads.append(dict(t, ref=r["ref"]))
    lines.append(f"threads[{len(threads)}]{{{','.join(THREAD_FIELDS)}}}:")
    lines += ["  " + ",".join(_cell(t[f]) for f in THREAD_FIELDS) for t in threads]
    if bad:
        lines.append(f"errors[{len(bad)}]{{ref,error}}:")
        lines += ["  " + ",".join(_cell(r[f]) for f in ("ref", "error")) for r in bad]
    lines.append(f"bot_threads_omitted: {bots}")
    lines.append(f"note: url is relative to {org.GITLAB_BASE}; approved_by lists are |-separated")
    return "\n".join(lines)


def _safe(kv, user):
    try:
        return facts(kv[0], kv[1], user)
    except Exception as e:  # report, never guess
        return {"ref": kv[0], "error": str(e)}


if __name__ == "__main__":
    main()
