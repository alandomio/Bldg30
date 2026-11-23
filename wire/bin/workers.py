#!/usr/bin/env python3
"""Write companion/workers.json: every worker of every firstmate home, local and remote, read-only.
Usage: workers.py [--out FILE]. Local homes: state/<id>.meta + the home's own fm-crew-state.sh; remote: home-summary.json.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json, os, re, subprocess, sys, tempfile, time
from pathlib import Path

MAIN = Path(os.environ.get("FM_MAIN_HOME") or Path.home() / "firstmate")
OUT = Path(os.environ.get("SHIPDECK_COMPANION", "~/Library/Application Support/ModelDeck/companion")).expanduser() / "workers.json"
MACHINE = os.uname().nodename.split(".")[0]
URL_RE = re.compile(r"https://[^\s)\"'<>,]+")
VERB_RE = re.compile(r"^(working|paused|done|needs-decision|blocked|failed|note|progress|resolved|pending-reply|captain-held)\b(.*?):\s?(.*)$")


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if epoch else None


def homes(main=MAIN):
    """[(name, home, host)] from the main registry; host None means this laptop."""
    out = [("main", str(main), None)]
    reg = main / "data" / "secondmates.md"
    for line in (reg.read_text().splitlines() if reg.is_file() else []):
        m = re.match(r"- ([\w-]+) - ", line)
        h = re.search(r"\(host: ([^;]+); root: [^;]+; home: ([^;]+);", line) or re.search(r"\(home: ([^;]+);", line)
        if m and h:
            out.append((m.group(1), h.group(2), h.group(1)) if h.lastindex == 2 else (m.group(1), h.group(1), None))
    return out


def parse_meta(text):
    return dict(l.split("=", 1) for l in text.splitlines() if "=" in l)


def last_event(status_path, mtime_fallback):
    """(verb, epoch, text) of the last event line that carries a verb, or Nones."""
    try:
        lines = Path(status_path).read_text(errors="replace").splitlines()
    except OSError:
        return None, None, ""
    for line in reversed(lines):
        m = VERB_RE.match(line)
        if m and m.group(1) not in ("note", "progress"):
            at = re.search(r"\[at=(\d+)\]", m.group(2))
            return m.group(1), int(at.group(1)) if at else mtime_fallback, m.group(3)
    return None, None, ""


def herdr_panes(run=subprocess.run):
    """{pane_id: agent_status} for this laptop's herdr ("exited" when the pane has no agent); empty when unreachable."""
    try:
        r = run(["herdr", "pane", "list"], capture_output=True, text=True, timeout=20)
        return {p["pane_id"]: (p.get("agent_status") or "unknown") if p.get("agent") else "exited" for p in json.loads(r.stdout)["result"]["panes"]}
    except Exception:
        return {}


def show_state(crew, verb, pane_status, pane_known):
    """One plain state for the card from crew-state, the last event and the pane."""
    if crew == "working":
        return "working"
    if crew == "parked":  # current state only: an old needs-decision line may be answered already
        return "waiting on a decision"
    if crew in ("paused", "blocked", "done", "failed"):
        return {"done": "done"}.get(crew, crew)
    if pane_known and pane_status is None:
        return "dead"
    return {"working": "working", "blocked": "waiting on a prompt", "idle": "idle", "done": "idle", "exited": "stopped"}.get(pane_status, "unknown")


def local_worker(home, wid, panes, now, run=subprocess.run):
    st = Path(home, "state")
    meta = parse_meta(Path(st, wid + ".meta").read_text(errors="replace"))
    if meta.get("kind") == "secondmate":
        return None
    try:
        r = run([str(Path(home, "bin", "fm-crew-state.sh")), wid], capture_output=True, text=True, timeout=45,
                env={**os.environ, "FM_HOME": home, "FM_CREW_STATE_NO_FORGE": "1"})
        line = (r.stdout.strip().splitlines() or [""])[0]
    except subprocess.TimeoutExpired:
        line = "state: unknown · source: none · crew-state timed out"
    parts = [p.strip() for p in line.split("·")]
    crew = parts[0].replace("state:", "").strip() or "unknown"
    detail = " · ".join(parts[2:]) if len(parts) > 2 else ""
    sp = Path(st, wid + ".status")
    mtime = int(sp.stat().st_mtime) if sp.exists() else None
    verb, at, text = last_event(sp, mtime)
    pane = (meta.get("window") or "").split(":", 1)[-1] if ":" in (meta.get("window") or "") else meta.get("herdr_pane_id")
    known = bool(panes) and meta.get("backend", "herdr") == "herdr" and bool(pane)
    state = show_state(crew, verb, panes.get(pane) if known else None, known)
    links = []
    for u in ([meta.get("pr")] if meta.get("pr") else []) + URL_RE.findall(text + " " + detail):
        if u and u not in links:
            links.append(u.rstrip("."))
    rep = Path(home, "data", wid, "report.md")
    if rep.is_file():
        links.append(str(rep))
    waits = text if state in ("waiting on a decision", "paused", "blocked", "failed", "waiting on a prompt") else ""
    return {"id": wid, "name": meta.get("title") or wid, "project": Path(meta.get("project") or "").name or meta.get("project", ""),
            "kind": meta.get("kind", ""), "harness": meta.get("harness", ""), "model": meta.get("model", ""),
            "state": state, "crew_state": crew, "detail": detail, "waiting_on": waits[:400],
            "last_activity_at": iso(at), "age_seconds": now - at if at else None, "links": links[:5]}


def collect_local(name, home, panes, now, run=subprocess.run):
    ids = sorted(p.stem for p in Path(home, "state").glob("*.meta"))
    with ThreadPoolExecutor(8) as ex:
        rows = [w for w in ex.map(lambda i: _safe(local_worker, home, i, panes, now, run), ids) if w]
    return {"name": name, "machine": MACHINE, "home": home, "remote": False, "ok": True, "error": None,
            "observed_at": iso(now), "workers": rows}


def _safe(fn, home, wid, panes, now, run):
    try:
        return fn(home, wid, panes, now, run)
    except Exception as e:  # one bad record never hides the home
        return {"id": wid, "name": wid, "state": "unknown", "detail": f"unreadable: {e}"[:200], "links": []}


REMOTE_STATE = {"working": "working", "parked": "waiting on a decision", "paused": "paused", "blocked": "blocked",
                "done": "done", "failed": "failed"}


def collect_remote(name, home, host, now, run=subprocess.run):
    base = {"name": name, "machine": host, "home": home, "remote": True, "observed_at": iso(now), "workers": []}
    try:
        r = run([str(MAIN / "bin" / "fm-on.sh"), name, "fm-remote-file.sh", "get", "state/home-summary.json", "1048576"],
                capture_output=True, text=True, timeout=120, env={**os.environ, "FM_HOME": str(MAIN)})
        s = json.loads(r.stdout)
    except Exception as e:
        return {**base, "ok": False, "error": f"remote summary not readable: {str(e)[:160]}"}
    gen = s.get("generated_epoch") or now
    seen, rows = set(), []
    for c in s.get("active_children", []) + s.get("endpoints", []):
        if c["id"] in seen:
            continue
        seen.add(c["id"])
        ep = (c.get("endpoint") or {}).get("status")
        state = REMOTE_STATE.get(c.get("state")) or ("dead" if ep == "absent" else "unknown")
        rows.append({"id": c["id"], "name": c.get("name") or c["id"], "project": Path(c.get("repo") or "").name,
                     "kind": c.get("kind", ""), "harness": "", "model": "", "state": state, "crew_state": c.get("state", ""),
                     "detail": c.get("doing", ""), "waiting_on": "", "last_activity_at": iso(gen), "age_seconds": now - gen, "links": []})
    for d in s.get("decisions_open", []):
        rows.append({"id": d["id"], "name": d.get("summary") or d["id"], "project": "", "kind": "decision", "harness": "", "model": "",
                     "state": "waiting on a decision", "crew_state": "", "detail": "", "waiting_on": (d.get("reason") or "")[:400],
                     "last_activity_at": None, "age_seconds": (d.get("hold_age_days") or 0) * 86400, "links": []})
    omitted = sum(o.get("count", 0) for o in s.get("omitted", []) if o.get("surface") == "endpoints")
    return {**base, "ok": True, "error": None, "summary_at": iso(gen), "omitted": omitted, "workers": rows}


def build(now=None, run=subprocess.run):
    now = now or int(time.time())
    panes = herdr_panes(run)
    hs = homes()
    with ThreadPoolExecutor(len(hs)) as ex:
        futs = [ex.submit(collect_remote, n, h, host, now, run) if host else ex.submit(collect_local, n, h, panes, now, run) for n, h, host in hs]
        out = []
        for (n, h, host), f in zip(hs, futs):
            try:
                out.append(f.result())
            except Exception as e:
                out.append({"name": n, "machine": host or MACHINE, "home": h, "remote": bool(host), "ok": False, "error": str(e)[:200], "workers": []})
    return {"schema": "companion-workers.v1", "generated_at": iso(now), "homes": out}


def write(doc, path=OUT):
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, indent=1)
    os.replace(tmp, path)


if __name__ == "__main__":
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else OUT
    doc = build()
    write(doc, out)
    print("workers: " + ", ".join(f"{h['name']} {len(h['workers'])}" + ("" if h["ok"] else " (error)") for h in doc["homes"]))
