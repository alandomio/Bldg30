#!/usr/bin/env python3
"""ShipDeck <-> firstmate wiring. Stdlib only; no agent turn, no launchd.

  wire.py feed-job    refresh feed.json (refresh.py from ai-skills !57) and then the dossiers; one run at a time
  wire.py dossiers    rebuild companion/dossiers/*.json from the current feed and firstmate records
  wire.py clicks      click bridge: companion-click.v1 files -> bin/fm-inbox.sh note, then mirror receipts into replies/ and commands.jsonl
                      (picked_up = filed, acknowledged = firstmate moved the note to handled/, done = fm-inbox reply); a click with
                      "nudges": <key> files a fresh note pointing at that waiting click (a new wake). One run at a time (state/clicks.lock);
                      ShipDeck runs it itself after each click and every minute, the main monitoring loop runs it too.
                      A captain-hold click (option, typed answer, Defer, Drop it) is recorded with fm-captain-hold.sh in the same run;
                      Drop and Defer then need no note, and a failed hold call leaves the click in the inbox for the next run.
  wire.py live        companion/live.json: newest 200 status events of state/*.status (fast, no network; also run by clicks)
  wire.py spawn-feed  start feed-job detached (used by the watcher check; the refresh takes minutes, a check gets 30 s)

State lives in data/shipdeck-wire/state/. Nothing here posts, approves or merges anything.
"""
import fcntl, glob, html, json, os, re, signal, subprocess, sys, tempfile, time
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Code (bin/, schema/) and runtime records (state/, purser/) sit together in the original firstmate home location
# (data/shipdeck-wire). From this repo, SHIPDECK_WIRE_HOME names the runtime folder and FM_HOME the firstmate home
# (see docs/shipdeck-wire.md); unset, both resolve exactly as before from where this file lives.
WIRE = Path(os.environ.get("SHIPDECK_WIRE_HOME") or HERE.parent).expanduser().resolve()
SCHEMA_DIR = HERE.parent / "schema"
FM_HOME = Path(os.environ.get("FM_HOME") or WIRE.parent.parent).resolve()
os.environ["FM_HOME"] = str(FM_HOME)
DATA = FM_HOME / "data"
STATE = WIRE / "state"
SUPPORT = Path(os.environ.get("SHIPDECK_COMPANION", "~/Library/Application Support/ModelDeck/companion")).expanduser()
FEED = SUPPORT / "feed.json"
INBOX, REPLIES, DOSSIERS = SUPPORT / "inbox", SUPPORT / "replies", SUPPORT / "dossiers"
PURSER = WIRE / "purser"
sys.path.insert(0, str(HERE))
import org  # noqa: E402  (organisation values, wire/bin/org.py)
import feed as feedlib  # noqa: E402  (pinned copy of ai-skills !57 feed.py: validator + atomic writer)

os.environ["PATH"] = ":".join([str(Path.home() / ".local/bin"), str(Path.home() / ".npm-global/bin"), "/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "/usr/bin:/bin")])


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def slug(ref):
    return re.sub(r"[^a-z0-9]+", "-", ref.lower()).strip("-") or "x"


def read_json(p, default=None):
    try:
        return json.loads(Path(p).read_text())
    except (OSError, ValueError):
        return default


def write_json(p, obj):
    feedlib.write_atomic(p, obj)


SKILL = Path(os.environ.get("SHIPDECK_SKILL", "~/.claude/skills/shipdeck/shipdeck")).expanduser()
SKILL_COMP = STATE / "live-companion"


def newest_board():
    """FM_SHIPDECK_BOARD when set; else an empty board, because rows now come live from the shipdeck skill (dated boards went stale)."""
    env = os.environ.get("FM_SHIPDECK_BOARD")
    if env:
        return env
    path = STATE / "live-board.json"
    write_json(path, {"date": datetime.now().date().isoformat(), "user": "adomio", "mrs": [], "tickets": [], "decisions": []})
    return str(path)


def skill_refresh(run=subprocess.run):
    """Live MR and ticket rows with card notes: `shipdeck refresh` into SKILL_COMP (cards shared with ShipDeck). Returns (feed, sidecar)."""
    SKILL_COMP.mkdir(parents=True, exist_ok=True)
    cards = SKILL_COMP / "cards"
    if not cards.is_symlink():
        cards.symlink_to(SUPPORT / "cards")
    import refresh  # Keychain reader; the key goes only into the child's environment
    key = refresh.read_key(refresh.DEFAULT_SERVICE) or ""
    r = run([str(SKILL), "refresh"], capture_output=True, text=True, timeout=600, env={**os.environ, "SHIPDECK_COMPANION": str(SKILL_COMP), "LINEAR_API_KEY": key})
    if r.returncode != 0:
        raise RuntimeError("shipdeck refresh failed: " + (r.stderr or r.stdout).replace(key or "\0", "***").strip()[-200:])
    return read_json(SKILL_COMP / "feed.json"), read_json(SKILL_COMP / "feed.actions.json", {})


def merge_live(feed, side, live, live_side):
    """Rows come from the live skill feed; the wire feed adds held decisions and review drafts, matched by MR URL."""
    by_url = {m["url"].rstrip("/"): m for m in feed.get("mrs", [])}
    mrs = []
    for m in live["mrs"]:
        w = by_url.pop(m["url"].rstrip("/"), None)
        if w and w.get("drafts"):
            have = {d["id"] for d in m.get("drafts") or []}
            m["drafts"] = (m.get("drafts") or []) + [d for d in w["drafts"] if d["id"] not in have]
            m["actions"] = [a for a in w["actions"] if ".comment-" in a["id"]] + m["actions"]
        mrs.append(m)
    mrs += [w for w in by_url.values() if w.get("drafts")]  # a review-draft card the live feed does not list
    feed["mrs"], feed["tickets"] = mrs, live.get("tickets", [])
    side["actions"] = {**(live_side or {}).get("actions", {}), **side.get("actions", {})}
    feed["warnings"] = [w for w in (feed.get("warnings") or []) + (live.get("warnings") or []) if not str(w).startswith("Card analysis is")]
    return feed, side


def holds_cmd():
    return f"{FM_HOME}/bin/fm-tasks-axi.sh list --state held --fields hold_reason,priority,created,held"


def set_status(name, ok, message=""):
    """Last result of a job. `reported` stays false until the check has told firstmate about this failure once."""
    prev = read_json(STATE / f"{name}.status.json", {})
    rec = {"ok": ok, "message": message[:400], "at": now_iso(), "reported": ok or (prev.get("message") == message[:400] and prev.get("reported", False))}
    write_json(STATE / f"{name}.status.json", rec)


# ---------------------------------------------------------------- feed
def feed_job():
    STATE.mkdir(parents=True, exist_ok=True)
    lock = STATE / "feed.lock"
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
    except FileExistsError:
        try:
            pid = int(lock.read_text() or 0)
            os.kill(pid, 0)
            return 0  # a refresh is still running
        except (ValueError, ProcessLookupError, PermissionError):
            lock.unlink(missing_ok=True)
            return feed_job()
    spawn_fleet()
    try:
        board = newest_board()
        if not Path(board).is_file():
            set_status("feed", False, f"no board.json found ({board})")
            return 1
        live, live_side = skill_refresh()  # first: it takes minutes, the merge below is instant
        r = subprocess.run([sys.executable, str(HERE / "refresh.py"), "--board", board, "--feed", str(FEED), "--holds-cmd", holds_cmd()],
                           capture_output=True, text=True, timeout=900)
        if r.returncode != 0:
            set_status("feed", False, (r.stderr or r.stdout).strip()[-300:] or f"refresh.py exit {r.returncode}")
            return 1
        warnings = [l for l in r.stderr.splitlines() if l.startswith("warning:")]
        side_path = FEED.with_name("feed.actions.json")
        feed, side = merge_live(read_json(FEED, {}), read_json(side_path, {}), live, live_side)
        write_json(side_path, side)
        write_json(FEED, feed)
        write_json(STATE / "feed-warnings.json", {"at": now_iso(), "warnings": warnings})
        errors = feedlib.validate(read_json(FEED, {}), feedlib.load_schema("companion-feed.v1"))
        if errors:
            set_status("feed", False, "feed.json invalid: " + "; ".join(errors[:3]))
            return 1
        set_status("feed", True, f"live rows {len(feed['mrs'])} MRs, {len(feed['tickets'])} tickets; decisions {len(feed.get('decisions', []))}")
        dossiers()
        return 0
    except subprocess.TimeoutExpired:
        set_status("feed", False, "refresh.py timed out after 900 s")
        return 1
    except Exception as e:  # never leave a stale lock
        set_status("feed", False, f"feed-job crashed: {e}")
        return 1
    finally:
        lock.unlink(missing_ok=True)


def spawn_fleet():
    """IN-3113: workers.json refreshes in its own session with its own lock, so a hung remote read never holds the feed."""
    lock = STATE / "fleet.lock"
    try:
        pid = int(lock.read_text() or 0)
        os.kill(pid, 0)
        if time.time() - lock.stat().st_mtime < 900:
            return  # still running and young
        os.kill(pid, signal.SIGKILL)  # hung across a sleep: replace it
    except (OSError, ValueError):
        pass
    p = subprocess.Popen([sys.executable, str(HERE / "workers.py")], stdin=subprocess.DEVNULL,
                         stdout=open(STATE / "workers.log", "a"), stderr=subprocess.STDOUT, start_new_session=True)
    lock.write_text(str(p.pid))


def spawn_feed():
    """Start feed-job as its own session (the check is killed after 30 s, the refresh takes about 2.5 minutes)."""
    lock = STATE / "feed.lock"
    if lock.exists():
        try:
            os.kill(int(lock.read_text() or 0), 0)
            return
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    STATE.mkdir(parents=True, exist_ok=True)
    log = open(STATE / "feed-job.log", "a")
    subprocess.Popen([sys.executable, str(HERE / "wire.py"), "feed-job"], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)


# ---------------------------------------------------------------- dossiers
def plain(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s or ""))).strip()


def iso_mtime(p):
    return datetime.fromtimestamp(os.path.getmtime(p), timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def record_files():
    files = []
    for pat in ("*/report.md", "*/context.md", "*/*decision*.md", "*/*card*.md"):
        files += glob.glob(str(DATA / pat))
    files += [str(DATA / "backlog.md")] if (DATA / "backlog.md").is_file() else []
    return sorted({f for f in files if os.path.getsize(f) < 400_000})


def needles(ref, url, ticket_ids):
    """Strings that name this exact item. An MR: its URL path. A ticket: its id as a whole word."""
    out = []
    if url and "/-/merge_requests/" in url:
        out.append(re.compile(re.escape(url.split("gitlab.com/")[-1]) + r"(?!\d)"))
    for t in ticket_ids:
        out.append(re.compile(rf"(?<![A-Za-z0-9]){re.escape(t)}(?!\d)", re.I))
    return out


_TEXT = {}
GOTCHA = re.compile(r"^\s*(?:[-*]\s*)?\**(gotcha|trap|obstacle)s?\**\s*[:\-]\s*(.+)$", re.I)


def scan_records(patterns, files):
    """(timeline, gotchas, links, sources) from firstmate files whose text names the item."""
    timeline, gotchas, links, sources = [], [], [], []
    for f in files:
        text = _TEXT.get(f)
        if text is None:
            try:
                text = _TEXT[f] = Path(f).read_text(errors="replace")
            except OSError:
                continue
        if not any(p.search(text) for p in patterns):
            continue
        rel = os.path.relpath(f, FM_HOME)
        title = next((l.lstrip("# ").strip() for l in text.splitlines() if l.startswith("#")), rel)
        at = iso_mtime(f)
        is_backlog = f.endswith("backlog.md")
        if is_backlog:
            for l in text.splitlines():
                if any(p.search(l) for p in patterns):
                    timeline.append({"at": at, "text": "Backlog: " + l.strip()[:240], "source": rel})
        else:
            timeline.append({"at": at, "text": f"Firstmate record: {title[:160]}", "source": rel})
            links.append({"label": title[:80], "url": "file://" + f})
        for l in text.splitlines():
            m = GOTCHA.match(l)
            if m and not is_backlog:
                gotchas.append({"text": m.group(2).strip()[:300], "source": rel})
        sources.append({"kind": "firstmate-record", "ref": rel, "at": at})
    return timeline, gotchas, links, sources


def purser_part(ref_slug):
    """Purser part, filled by firstmate during its heartbeat into purser/<key>.json (see report.md, Purser hook)."""
    for key in (f"board-mr-{ref_slug}", f"board-t-{ref_slug}"):
        rec = read_json(PURSER / f"{key}.json")
        if rec:
            return key, rec
    return None, None


def build_dossier(item, kind, feed, board_rows, files):
    ref = item["ref"] if kind == "mr" else item["identifier"]
    url = item["url"]
    sl = slug(ref)
    brow = board_rows.get(ref.lower()) or {}
    ticket_ids = [item["identifier"]] if kind == "ticket" else ([str(brow["ticket"])] if brow.get("ticket") else [])
    tl, gotchas, links, sources = scan_records(needles(ref, url, ticket_ids), files)
    links = [{"label": ref, "url": url}] + links
    sources.insert(0, {"kind": "feed", "ref": ref, "at": feed.get("generated_at", "")})
    if brow:
        sources.append({"kind": "board", "ref": os.path.relpath(brow["_board"], FM_HOME)})
    dec_id = item.get("decision_id")
    decisions = [{"id": d["id"], "title": d["title"], "recommendation": d.get("recommendation", ""), "links": d.get("links", [])}
                 for d in feed.get("decisions", []) if d["id"] == dec_id or (url and url in d.get("links", []))]
    if kind == "mr":
        bits = [item.get("title", ""), f"Pipeline {item.get('pipeline') or 'unknown'}, {item.get('open_threads') if item.get('open_threads') is not None else '?'} open thread(s), next: {item.get('next_owner')}."]
        summary = " ".join(b for b in bits if b)
        next_action = plain(brow.get("headline") or brow.get("next") or item.get("label", ""))
    else:
        summary = f"{item.get('title', '')} Status {item.get('status') or 'unknown'}; finish step: {item.get('finish', {}).get('step', '')} ({item.get('finish', {}).get('owner', '')})."
        next_action = plain(brow.get("headline") or brow.get("next") or item.get("finish", {}).get("step", ""))
    if brow.get("why"):
        summary += " " + plain(brow["why"])
    pkey, prec = purser_part(sl)
    if prec:
        sources.append({"kind": "purser", "ref": pkey, "at": prec.get("updated_at", "")})
        summary = (prec.get("summary") or summary)
        tl += [{"at": e.get("at", ""), "text": e["text"], "source": pkey} for e in prec.get("timeline", []) if e.get("text")]
        gotchas += [{"text": g if isinstance(g, str) else g.get("text", ""), "source": pkey} for g in prec.get("gotchas", [])]
        links += [{"label": l.get("label", l.get("url", "")), "url": l["url"]} for l in prec.get("links", []) if l.get("url")]
        next_action = prec.get("next_action") or next_action
    seen, uniq_links = set(), []
    for l in links:
        if l["url"] and l["url"] not in seen:
            seen.add(l["url"])
            uniq_links.append(l)
    tl.sort(key=lambda e: e["at"], reverse=True)
    return sl, {"schema": "companion-dossier.v1", "ref": ref, "summary": summary.strip(), "timeline": tl[:30], "open_decisions": decisions,
                "gotchas": [g for g in gotchas if g["text"]][:20], "links": uniq_links, "next_action": next_action, "generated_at": now_iso(), "sources": sources}


def dossiers():
    feed = read_json(FEED)
    if not feed:
        print("dossiers: no feed", file=sys.stderr)
        return 1
    board_path = newest_board()
    board = read_json(board_path, {})
    rows = {}
    for m in board.get("mrs", []):
        for r in m.get("refs", []):
            rows[r[1].lower()] = {**m, "_board": board_path}
    for t in board.get("tickets", []):
        rows[str(t.get("id", "")).lower()] = {**t, "_board": board_path}
    files = record_files()
    schema = json.loads((SCHEMA_DIR / "companion-dossier.v1.schema.json").read_text())
    DOSSIERS.mkdir(parents=True, exist_ok=True)
    wanted, pending, bad = set(), [], []
    for kind, key in (("mr", "mrs"), ("ticket", "tickets")):
        for item in feed.get(key, []):
            sl, d = build_dossier(item, kind, feed, rows, files)
            errs = feedlib.validate(d, schema)
            if errs:
                bad.append(f"{d['ref']}: {errs[0]}")
                continue
            write_json(DOSSIERS / f"{sl}.json", d)
            wanted.add(f"{sl}.json")
            if not any(s["kind"] == "purser" for s in d["sources"]):
                pending.append({"ref": d["ref"], "purser_key": ("board-mr-" if kind == "mr" else "board-t-") + sl, "write_to": str((PURSER / (("board-mr-" if kind == "mr" else "board-t-") + sl + ".json")).relative_to(FM_HOME))})
    for old in DOSSIERS.glob("*.json"):  # a closed item leaves the feed, so its dossier goes too
        if old.name not in wanted:
            old.unlink()
    write_json(STATE / "purser-pending.json", {"generated_at": now_iso(), "count": len(pending), "items": pending})
    if bad:
        set_status("dossiers", False, "; ".join(bad[:3]))
        return 1
    set_status("dossiers", True, f"{len(wanted)} dossiers")
    print(f"dossiers: wrote {len(wanted)}")
    return 0


def decision_option(click):
    """(decision, option) from feed.json for a held decision's option click, or None."""
    for d in (read_json(FEED, {}) or {}).get("decisions", []):
        for o in d.get("options", []):
            if o.get("action_id") == click["action_id"]:
                return d, o
    rec = read_json(STATE / HOLD_CLICKS, {}).get(click.get("idempotency_key"))  # answered on an earlier run, gone from a newer feed
    return ({"id": rec["hold"], "title": rec.get("title", rec["hold"])}, rec["option"]) if rec else None


# ---------------------------------------------------------------- captain holds
HOLD_CLICKS = "hold-clicks.json"  # in STATE: idempotency key -> hold answered by the bridge (survives a failed note filing)
HOLD_SH = None  # tests point this at bin/fm-captain-hold.sh of the firstmate checkout; default: FM_HOME/bin


class HoldRetry(Exception):
    """The hold owner could not be asked or gave no verdict: keep the click in the inbox and retry next run."""


def run_hold(args, body=None, tool="fm-captain-hold.sh"):
    sh = Path(HOLD_SH or FM_HOME / "bin" / "fm-captain-hold.sh")
    env = {k: v for k, v in os.environ.items() if k not in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_ROOT_OVERRIDE")}
    try:
        return subprocess.run([str(sh.parent / tool)] + args, input=body, capture_output=True, text=True, env={**env, "FM_HOME": str(FM_HOME)}, timeout=90)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise HoldRetry(f"{tool} {args[0]}: {e}")


def hold_reason(hold_id):
    """The hold's current reason, decoded by fm-tasks-axi.sh show (re-holding needs it unchanged)."""
    r = run_hold(["show", hold_id, "--full"], tool="fm-tasks-axi.sh")
    m = re.search(r'^\s*hold_reason: (".*"|[^\n]*)$', r.stdout, re.M) if r.returncode == 0 else None
    if not m:
        raise HoldRetry(f"cannot read the reason of hold {hold_id}: {(r.stderr or r.stdout).strip()[:120]}")
    v = m.group(1)
    return json.loads(v) if v.startswith('"') else v


def tsv_field(text, key):
    """One field of an fm-captain-hold.sh answers row: line breaks and tabs become spaces, as the intake's own sanitizer does after
    splitting, so typed text can never start another row; the intake keeps 512 characters, the full text stays in the click and note."""
    t = re.sub(r"[\x00-\x1f\x7f]", "", re.sub(r"[\r\n\t]", " ", text)).strip()
    return t if len(t) <= 512 else t[:440].rstrip() + f" ... (full text: ShipDeck click {key})"


def apply_hold(click, d, o):
    """Record a held decision's option click on its hold with fm-captain-hold.sh, the hold's owner.
    Returns None when the decision is no captain hold here (a board decision), else (state, text, filed):
    state done/failed is final for Drop and Defer; "answered" means the answer is recorded and the hold released, and firstmate still acts."""
    hid, aid = d["id"], click["action_id"]
    free = aid == hid + ".answer"
    if not (free or aid.startswith(hid + ".opt-")) or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", hid):
        return None
    r = run_hold(["open", hid, "--distinguish-absent"])
    if r.returncode == 3:
        return None
    if r.returncode not in (0, 1):
        raise HoldRetry(f"fm-captain-hold.sh open {hid} exit {r.returncode}: {r.stderr.strip()[:120]}")
    if aid.endswith(".opt-defer"):
        if r.returncode == 1:
            return "failed", f"Hold {hid} is no longer open; not deferred.", False
        until = (datetime.now() + timedelta(days=7)).date().isoformat()
        h = run_hold(["hold", hid, "--reason", hold_reason(hid), "--until", until])
        if h.returncode != 0:
            return "failed", f"fm-captain-hold.sh hold {hid} --until {until} refused: {(h.stderr or h.stdout).strip()[:200]}", False
        return "done", f"Deferred: hold {hid} kept, back on {until}.", False
    drop = aid.endswith(".opt-drop")
    words = click["draft_text"].strip() if free else f"{o['label']}: {o.get('consequence', '')}".strip(": ")
    if click.get("draft_text") and not free:
        words += f" Alan's text: {click['draft_text']}"
    # Drop closes (done). A feed card declares no close mode, so like a raw Bearings card an answer releases:
    # held work proceeds, and firstmate closes a question-shaped call from the note.
    key = click["idempotency_key"]
    line = "\t".join([hid, tsv_field(words, key), tsv_field(o["label"], key), "done" if drop else "release"]) + "\n"
    a = run_hold(["answers", "--source", f"ShipDeck click {click['idempotency_key']}"], line)
    out = (a.stdout + a.stderr).strip()
    if f"closed: {hid}" in a.stdout:
        if drop:
            return "done", f"Dropped: hold {hid} closed with Alan's answer.", False
        return "answered", (f"Hold {hid} answered by the click bridge ({'his typed answer' if free else o['label']}) and released with fm-captain-hold.sh answers mode release. "
                            "If the task is question-shaped, close it now (it is no longer held); if it is gated work, let it proceed."), True
    skip = re.search(rf"^(?:skipped|refused): {re.escape(hid)} \((.*)\)$", a.stdout, re.M)
    if skip:
        if drop and skip.group(1) == "already closed":
            return "done", f"Hold {hid} was already closed; nothing changed.", False
        return "failed", f"Hold {hid} not answered: {skip.group(1)[:200]}", False
    raise HoldRetry(f"fm-captain-hold.sh answers {hid} exit {a.returncode}: {out[:160]}")


# ---------------------------------------------------------------- click bridge
WORKER_ACTIONS = {
    "worker.sweep": ("Sweep finished worker", True,
        "Alan swept this finished worker, which counts as him having seen its result. First check the worker has no unposted review drafts and no open decision (look in feed.json drafts with source = the task, and fm-captain-hold.sh); "
        "if it has, do nothing and set the command to failed with that reason as the note. Otherwise record its report as delivered with fm-captain-hold.sh (the text below is the verdict line he saw), then run fm-teardown.sh for the task."),
    "worker.cleanup": ("Clean up worker", True,
        "Clean up this worker with fm-teardown.sh. Refuse when the worker has unposted work, unmerged commits or an open decision, and say why: set the command to failed with the refusal as the note, so ShipDeck offers Discard."),
    "worker.discard": ("Discard worker and clean up", True,
        "Alan confirmed discarding this worker after a refused cleanup, with the list of what is lost shown to him. Run fm-teardown.sh with its discard option, and report what was removed."),
    "worker.merge": ("Merge worker result", True,
        "Merge this worker's result under the usual merge authority gates (fm-merge-authority-lib.sh); do nothing outside them."),
    "worker.steer": ("Steer worker", False,
        "Send the text below to this worker with fm-send.sh. It is an instruction for the worker, not an approval to post anything outward."),
    "worker.spawn": ("Spawn worker", False,
        "Spawn a new worker for this target with fm-spawn.sh under the usual gates."),
}


def worker_task(click):
    """Task id of a worker.* click whose target is a worker of this home (a state/<id>.meta exists), else None."""
    m = re.match(r"^worker:([\w.-]+)$", click.get("target") or "")
    return m.group(1) if m and (FM_HOME / "state" / f"{m.group(1)}.meta").is_file() else None


def click_body(click, side, hold=None):
    act = side.get(click["action_id"])
    worker = WORKER_ACTIONS.get(click["action_id"]) if not act else None
    lines = [f"ShipDeck click: {act['label'] if act else click['action_id']}", f"Action id: {click['action_id']}", f"Target: {click['target']}",
             f"Created: {click['created_at']}", f"Idempotency key: {click['idempotency_key']}"]
    free = click["action_id"].endswith(".answer")
    if worker:
        label, outward, how = worker
        task = worker_task(click)
        lines[0] = f"ShipDeck click: {label}"
        if not task:
            lines += ["", f"Target {click['target']} is not a worker of this home (no state file): reply 'no such worker', do nothing."]
        else:
            lines += [f"Outward (posts or changes something): {'yes' if outward else 'no'}", "", f"Worker click for task {task} (ShipDeck Workers tab, approved by Alan in the app): {how}",
                      "Report the result in a note and mark the command done or failed."]
    elif act:
        lines.append(f"Outward (posts or changes something): {'yes' if act.get('outward') else 'no'}")
        lines += ["", "Board prompt this click maps to (run it under the usual gates):", act["prompt"]]
    elif free and hold:
        lines += ["", f"Free answer to decision {click['target']}: {hold} Do not answer the hold again; act on his words under the usual gates and reply to this note with the result."]
    elif free:
        lines += ["", "Free answer to decision " + click["target"] + ": read the text below as Alan's answer or extra context for that hold."]
    elif re.match(r"^.+\.opt-[\w-]+$", click["action_id"]) and decision_option(click):
        # A held decision's option: an answer to that hold, recorded with Alan's words through fm-captain-hold answer.
        d, o = decision_option(click)
        lines += ["", f"Answer to decision {d['id']} ({d['title']}): Alan chose option '{o['label']}' ({o.get('consequence', '')})."]
        if hold:
            lines.append(f"{hold} Do not answer the hold again; act on the choice under the usual gates and reply to this note with the result.")
        elif click["action_id"].endswith(".opt-defer"):
            lines.append("Defer: re-hold it with fm-captain-hold.sh hold <id> --until <today + 7 days>, keeping its reason; record Alan's words.")
        elif click["action_id"].endswith(".opt-drop"):
            lines.append("Drop: close it with fm-captain-hold.sh answer <id> --decision-file <his words> (no --release: that would put it back in the queue); nothing changes outside firstmate.")
        else:
            lines.append("Record it with fm-captain-hold.sh answer (his words: the option label plus any text below), then act on it under the usual gates.")
    elif click["action_id"].endswith(".decide-options"):
        lines += ["", f"Decision on the delivery-buddy options of {click['target']}: Alan picked one option per group on the ShipDeck ticket card "
                  "(the picked lines and the run they answer are below). Record the decision on the ticket's hold or buddy task, then act on it under the usual gates.",
                  "Answer with bin/fm-inbox.sh reply <this note's id> - (one or two plain lines: what was recorded and the next step); ShipDeck shows it under the options."]
    elif click["action_id"].endswith(".ask-delivery-buddy"):
        lines += ["", f"Ask delivery buddy on {click['target']} (ShipDeck ticket card): run the delivery-buddy skill for this ticket, read only. "
                  "Read the ticket and its linked MRs live, then say the current step, the evidence for it, and the single next action to bring it to Done.",
                  "Answer with bin/fm-inbox.sh reply <this note's id> - (a few plain lines); ShipDeck shows the reply as a comment on the ticket card. "
                  "Do not act on the ticket, its MRs or anything outward from this click."]
    elif click["action_id"].endswith(".add-context"):
        # Same handling as the Lavish board's "Add context" button (render.py addContext).
        lines += ["", f"Add context on {click['target']}: append the text below, dated, to the board task (Purser record); run a {org.KNOWLEDGE_SEARCH} and attach the matching cards (slug and title); if a colleague needs this context, draft a Linear comment or MR note in Alan's voice and show it for Post/Edit/Discard, posting nothing."]
    else:
        lines.append("Action id is not in feed.actions.json: treat as stale, reply 'no longer on the board', do nothing.")
    if click.get("draft_text"):
        # Only an outward action's text is approved outward text; anything else is an answer or context, never a post approval.
        head = "Draft text approved in ShipDeck (exact):" if act and act.get("outward") else "Text typed in ShipDeck (answer or context, not an approval to post):"
        lines += ["", head, click["draft_text"]]
    lines += ["", "Handling guide: ai-skills linear-action-board companion/README.md, section 'Handling a companion-click.v1 inbox note'."]
    return "\n".join(lines) + "\n"


# Deck Officer (owner of ShipDeck) has its own home; comment clicks are filed there, everything else goes to FM_HOME.
DECK_OFFICER_HOME = Path(os.environ.get("DECK_OFFICER_HOME") or Path.home() / ".treehouse/firstmate-753674/3/firstmate")
COMMENT_ACTION = "comment_deck_officer"


def run_inbox(args, body=None, home=None):
    home = home or FM_HOME
    return subprocess.run([str(home / "bin" / "fm-inbox.sh")] + args, input=body, capture_output=True, text=True, env={**os.environ, "FM_HOME": str(home)}, timeout=25)


def comment_body(click):
    return "\n".join([
        "ShipDeck comment for Deck Officer (typed in the ShipDeck comment box, not an approval to post anything outward).",
        f"Target: {click['target']}", f"Created: {click['created_at']}", f"Idempotency key: {click['idempotency_key']}", "",
        "Comment text (full):", click.get("draft_text") or "(empty)", "",
        "Reply by writing a companion-reply.v1 file with status and \"text\" to "
        f"{REPLIES}/{click['idempotency_key']}.json (idempotency_key = the key above, note_id = this note's id, status done). ShipDeck shows the text under the comment.",
    ]) + "\n"


def hold_click(click, f, seen, handled, errors):
    """Apply a captain-hold option click in this turn. Returns None (no hold: file the note as usual), the answer text for the note,
    "final" (Drop or Defer recorded, or refused, without a note) or "retry" (click left in the inbox)."""
    key = click["idempotency_key"]
    done = read_json(STATE / HOLD_CLICKS, {})
    if key in done:
        return done[key]["text"]
    if click["action_id"] == click["target"] + ".answer" and (click.get("draft_text") or "").strip():
        do = ({"id": click["target"], "title": click["target"]}, {"label": "Free answer", "consequence": ""})
    elif re.match(r"^.+\.opt-[\w-]+$", click["action_id"]):
        do = decision_option(click)
    else:
        return None
    if not do:
        return None
    try:
        res = apply_hold(click, *do)
    except HoldRetry as e:
        errors.append(f"{f.name}: hold not changed, retrying next run: {e}")
        return "retry"
    if not res:
        return None
    state, text, filed = res
    if filed:
        done[key] = {"hold": do[0]["id"], "title": do[0].get("title", ""), "option": do[1], "text": text, "at": now_iso()}
        write_json(STATE / HOLD_CLICKS, done)
        return text
    seen[key] = {"note_id": "-", "file": f.name, "at": now_iso(), "action_id": click["action_id"], "target": click["target"], "hold": text}
    cmd_log(seen[key], key, state, text)
    out = {"schema": "companion-reply.v1", "idempotency_key": key, "note_id": "-", "status": "done" if state == "done" else "rejected", "text": text, "updated_at": now_iso()}
    write_json(REPLIES / f"{key}.json", out)
    if state == "done":
        write_json(handled / (f.stem + ".reply.json"), out)
    write_json(STATE / "clicks.json", seen)
    os.replace(f, handled / f.name)
    return "final"


def clicks():
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / "clicks.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("clicks: another run is active")  # ShipDeck and the monitoring loop both run the bridge
            return 0
        return _clicks()


def _clicks():
    schema = feedlib.load_schema("companion-click.v1")
    map_path = STATE / "clicks.json"
    seen = read_json(map_path, {})
    side = (read_json(SUPPORT / "feed.actions.json", {}) or {}).get("actions", {})
    handled = INBOX / "handled"
    errors = []
    if INBOX.is_dir():
        handled.mkdir(exist_ok=True)
        REPLIES.mkdir(parents=True, exist_ok=True)
        for f in sorted(INBOX.glob("*.json")):
            if f.name.endswith(".reply.json"):
                continue
            click = read_json(f)
            errs = feedlib.validate(click, schema) if isinstance(click, dict) else ["not a JSON object"]
            if errs:
                key = f.stem
                write_json(REPLIES / f"{key}.json", {"schema": "companion-reply.v1", "idempotency_key": key if len(key) >= 8 else key.ljust(8, "_"), "note_id": "-", "status": "rejected", "text": "; ".join(errs[:2]), "updated_at": now_iso()})
                (INBOX / "rejected").mkdir(exist_ok=True)
                os.replace(f, INBOX / "rejected" / f.name)
                continue
            key = click["idempotency_key"]
            if click.get("nudges"):
                err = nudge(click, seen)
                if err:
                    errors.append(f"{f.name}: {err}")
                    continue
                write_json(map_path, seen)
                os.replace(f, handled / f.name)
                continue
            to_officer = click["action_id"] == COMMENT_ACTION
            home = DECK_OFFICER_HOME if to_officer else None
            held = None if to_officer or click["action_id"] in side else hold_click(click, f, seen, handled, errors)
            if held == "final" or held == "retry":
                continue
            try:
                r = run_inbox(["note", "--request-id", f"shipdeck-{key}", "--json", "-"], comment_body(click) if to_officer else click_body(click, side, held), home=home)
            except (OSError, subprocess.TimeoutExpired) as e:
                errors.append(f"{f.name}: fm-inbox note failed: {e}")
                continue
            if r.returncode not in (0, 3):
                errors.append(f"{f.name}: fm-inbox note failed ({r.returncode}): {r.stderr.strip()[:120]}")
                continue
            try:
                note_id = json.loads(r.stdout.strip().splitlines()[-1])["id"]
            except (ValueError, KeyError, IndexError):
                errors.append(f"{f.name}: unreadable fm-inbox answer")
                continue
            if r.returncode == 3:
                try:
                    run_inbox(["announce", "--json", note_id], home=home)
                except (OSError, subprocess.TimeoutExpired) as e:
                    errors.append(f"{f.name}: fm-inbox announce failed: {e}")
            seen[key] = {"note_id": note_id, "file": f.name, "at": now_iso(),
                         "action_id": click.get("action_id"), "target": click.get("target")}
            if to_officer:
                seen[key]["home"] = "deck_officer"
            if held:
                seen[key]["hold"] = held
            cmd_log(seen[key], key, "picked_up", "hold answered; filed for firstmate to act" if held else "filed for firstmate")
            write_json(map_path, seen)
            os.replace(f, handled / f.name)  # ShipDeck reads handled/ as "picked up"
    errors += mirror_receipts(seen, handled)
    write_json(map_path, seen)
    try:
        if live():
            errors.append("live: invalid live.json, not written")
    except Exception as e:  # a live-feed problem must not hide the click result
        errors.append(f"live: {e}")
    set_status("clicks", not errors, "; ".join(errors))
    return 1 if errors else 0


LIVE = SUPPORT / "live.json"
LIVE_MAX = 200
HEAD_RE = re.compile(r"^([a-z][a-z-]*)((?:\s+(?:\[[^\]]*\]|\w+=\S+))*)$")


def parse_status_line(line):
    """(state, key, epoch, text) for `state [key=x] [at=N]: text`; None for lines without a state and an at= time."""
    head, sep, text = line.partition(":")
    m = HEAD_RE.match(head.strip())
    if not sep or not m:
        return None
    at = re.search(r"\bat=(\d{9,11})\b", m.group(2))
    key = re.search(r"\bkey=([^\]\s]+)", m.group(2))
    if not at:
        return None
    return m.group(1), key.group(1) if key else None, int(at.group(1)), text.strip()


def live_events():
    events = []
    for f in sorted((FM_HOME / "state").glob("*.status")):
        try:
            lines = f.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            p = parse_status_line(line)
            if p:
                state, key, at, text = p
                ev = {"task": f.name[:-len(".status")], "state": state, "at": datetime.fromtimestamp(at, timezone.utc).isoformat().replace("+00:00", "Z"), "text": text[:600]}
                if key:
                    ev["key"] = key
                events.append((at, ev))
    events.sort(key=lambda x: x[0], reverse=True)
    return [e for _, e in events[:LIVE_MAX]]


def live():
    doc = {"schema": "companion-live.v1", "generated_at": now_iso(), "events": live_events()}
    errs = feedlib.validate(doc, feedlib.load_schema("companion-live.v1"))
    if errs:
        print("live.json invalid: " + "; ".join(errs[:3]), file=sys.stderr)
        return 1
    write_json(LIVE, doc)
    return 0


COMMANDS = SUPPORT / "commands.jsonl"  # format: bldg30 COMMANDS.md
FINAL = ("done", "failed")


def _append_cmd(m, key, state, note):
    if not (m.get("action_id") and m.get("target")):  # records filed before action_id was kept: read it from the handled click
        c = read_json(INBOX / "handled" / m.get("file", ""), {}) or {}
        m["action_id"], m["target"] = m.get("action_id") or c.get("action_id"), m.get("target") or c.get("target")
    line = {"id": key, "action_id": m.get("action_id"), "target": m.get("target"), "state": state, "at": now_iso(), "note": note}
    fd = os.open(COMMANDS, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, (json.dumps(line) + "\n").encode())
    finally:
        os.close(fd)


def cmd_log(m, key, state, note):
    """Append one forward-only transition to commands.jsonl, once per state per click."""
    done = m.setdefault("cmd_states", [])
    if state in done or any(s in done for s in FINAL):
        return
    _append_cmd(m, key, state, note)
    done.append(state)


def note_body(home, note_id):
    """Text of a firstmate note (pending or handled), or None."""
    inbox = Path(home or FM_HOME) / "state" / "inbox"
    for p in (inbox / f"{note_id}.note", inbox / "handled" / f"{note_id}.note"):
        try:
            return p.read_text(errors="replace")
        except OSError:
            continue
    return None


def nudge(click, seen):
    """A ShipDeck nudge for an earlier click: file a fresh note pointing at the original one when firstmate has not acknowledged it.
    The nudge itself gets a reply file, never a commands.jsonl entry of its own. Returns an error text or None."""
    key, orig_key = click["idempotency_key"], click["nudges"]
    m = seen.get(orig_key)

    def reply(status, text, nid="-"):
        write_json(REPLIES / f"{key}.json", {"schema": "companion-reply.v1", "idempotency_key": key, "note_id": nid, "status": status, "text": text, "updated_at": now_iso()})

    if not m:
        reply("rejected", f"no filed click {orig_key}: nothing to nudge")
        return None
    home = DECK_OFFICER_HOME if m.get("home") == "deck_officer" else None
    acked = any(s in m.get("cmd_states", []) for s in ("acknowledged",) + FINAL)
    if not acked:
        try:
            pending, handled_ids, replies = _receipts(home)
            acked = m["note_id"] in handled_ids or m["note_id"] in replies
        except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as e:
            return f"nudge: fm-inbox receipts failed: {str(e)[:120]}"
    if acked:
        reply("done", "already acknowledged", m["note_id"])
        return None
    orig_click = read_json(INBOX / "handled" / m.get("file", ""), {}) or {}
    since = orig_click.get("created_at") or m.get("at")
    body = (f"ShipDeck nudge: click {m.get('action_id')} on {m.get('target')} waits since {since}, original note {m['note_id']}\n\n"
            + (note_body(home, m["note_id"]) or "(original note body not readable)\n"))
    try:
        r = run_inbox(["note", "--request-id", f"shipdeck-nudge-{key}", "--json", "-"], body, home=home)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"nudge: fm-inbox note failed: {e}"
    if r.returncode not in (0, 3):
        return f"nudge: fm-inbox note failed ({r.returncode}): {r.stderr.strip()[:120]}"
    try:
        new_id = json.loads(r.stdout.strip().splitlines()[-1])["id"]
    except (ValueError, KeyError, IndexError):
        return "nudge: unreadable fm-inbox answer"
    if r.returncode == 3:
        try:
            run_inbox(["announce", "--json", new_id], home=home)
        except (OSError, subprocess.TimeoutExpired) as e:
            return f"nudge: fm-inbox announce failed: {e}"
    # A second picked_up line on purpose: the app keeps the wait start and shows the note.
    _append_cmd(m, orig_key, "picked_up", f"nudged {now_iso()}")
    m.setdefault("nudges", []).append({"at": now_iso(), "note_id": new_id, "click": key})
    reply("done", f"nudge filed as note {new_id}", new_id)
    return None


def _receipts(home):
    r = run_inbox(["receipts", "--all-pending", "--all-handled", "--all-replies"], home=home)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:120])
    rec = json.loads(r.stdout)
    return ({n["id"] for n in rec.get("pending", [])}, {n["id"] for n in rec.get("handled", [])}, {x["id"]: x for x in rec.get("replies", [])})


def mirror_receipts(seen, handled):
    if not seen:
        return []
    errors, recs = [], {}
    for name, home in (("main", None), ("deck_officer", DECK_OFFICER_HOME)):
        if name != "main" and not any(m.get("home") == name for m in seen.values()):
            continue
        try:
            recs[name] = _receipts(home)
        except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as e:
            errors.append(f"fm-inbox receipts failed ({name}): {str(e)[:120]}")
    REPLIES.mkdir(parents=True, exist_ok=True)
    for key, m in seen.items():
        nid = m["note_id"]
        if m.get("home", "main") not in recs:
            continue
        pending, acked, replies = recs[m.get("home", "main")]
        if nid in replies:
            status, text = "done", replies[nid]["body"].strip()
        elif nid in acked:
            status, text = "picked_up", ""
        elif nid in pending:
            status, text = "queued", ""
        else:
            continue
        if status == "done":
            cmd_log(m, key, "done", text[:300] or "replied by firstmate")
        elif nid in acked:
            cmd_log(m, key, "acknowledged", "acknowledged by firstmate")
        out = {"schema": "companion-reply.v1", "idempotency_key": key, "note_id": nid, "status": status, "updated_at": now_iso()}
        if text:
            out["text"] = text
        dest = REPLIES / f"{key}.json"
        old = read_json(dest, {})
        if old.get("text") and not out.get("text"):
            continue  # never replace a reply that carries text with a bare receipt
        if (old.get("status"), old.get("text")) != (status, out.get("text")):
            write_json(dest, out)
        if status == "done":  # the file ShipDeck's status reader looks for beside the handled note
            rf = handled / (Path(m["file"]).stem + ".reply.json")
            if not rf.exists():
                write_json(rf, out)
    return errors


def check_report(names):
    """Print each failed job once (the check output is what wakes firstmate); print nothing when all is well or already reported."""
    for name in names:
        st = read_json(STATE / f"{name}.status.json", {})
        if st and not st.get("ok") and not st.get("reported"):
            print(f"shipdeck-wire {name} failed: {st.get('message', '')}")
            st["reported"] = True
            write_json(STATE / f"{name}.status.json", st)
    return 0


def main(argv):
    if len(argv) > 1 and argv[1] == "check-report":
        return check_report(argv[2:])
    cmd = argv[1] if len(argv) > 1 else ""
    return {"feed-job": feed_job, "dossiers": dossiers, "clicks": clicks, "live": live, "spawn-feed": lambda: spawn_feed() or 0}.get(cmd, lambda: print(__doc__) or 2)()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
