"""companion-feed.v1 writer: the board rows render.py draws, as JSON for a companion app.
render.py calls build() after every board check, so the feed reuses those rules. Stdlib only.
"""
import json, os, re, shlex, subprocess, tempfile
from datetime import datetime, timezone
from pathlib import Path

import org

SCHEMA_DIR = Path(__file__).with_name("companion") / "schema"
LINEAR_BASE = org.LINEAR_ISSUE_BASE
META_LINE = re.compile(r"^\s*(one top-level|placement:|general mr note|single general comment)", re.I)
RULE = re.compile(r"^\s*-{3,}\s*$")
URGENT = {"urgent", "high"}


def load_schema(name):
    return json.loads((SCHEMA_DIR / f"{name}.schema.json").read_text())


def _is_type(v, t):
    return {"object": isinstance(v, dict), "array": isinstance(v, list), "string": isinstance(v, str),
            "boolean": isinstance(v, bool), "null": v is None,
            "integer": isinstance(v, int) and not isinstance(v, bool)}[t]


def validate(v, schema, root=None, path="$"):
    """Errors for the JSON Schema subset the companion schemas use (type, enum, const, required, properties,
    items, anyOf, $ref, minLength, minItems, minimum, pattern); [] when valid."""
    root = root or schema
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        return validate(v, node, root, path)
    err = []
    if "const" in schema and v != schema["const"]:
        err.append(f"{path}: must be {schema['const']!r}")
    if "enum" in schema and v not in schema["enum"]:
        err.append(f"{path}: {v!r} not one of {schema['enum']}")
    types = schema.get("type")
    if types and not any(_is_type(v, t) for t in ([types] if isinstance(types, str) else types)):
        return err + [f"{path}: expected {types}, got {type(v).__name__}"]
    if isinstance(v, str):
        if len(v) < schema.get("minLength", 0):
            err.append(f"{path}: too short")
        if "pattern" in schema and not re.search(schema["pattern"], v):
            err.append(f"{path}: {v!r} does not match {schema['pattern']}")
    if isinstance(v, int) and not isinstance(v, bool) and v < schema.get("minimum", v):
        err.append(f"{path}: below {schema['minimum']}")
    if isinstance(v, list):
        if len(v) < schema.get("minItems", 0):
            err.append(f"{path}: needs at least {schema['minItems']} item(s)")
        for i, item in enumerate(v):
            err += validate(item, schema.get("items", {}), root, f"{path}[{i}]")
    if isinstance(v, dict):
        err += [f"{path}: missing {k!r}" for k in schema.get("required", []) if k not in v]
        for k, sub in schema.get("properties", {}).items():
            if k in v:
                err += validate(v[k], sub, root, f"{path}.{k}")
    if "anyOf" in schema and not any(not validate(v, s, root, path) for s in schema["anyOf"]):
        err.append(f"{path}: matches none of the allowed shapes (a row needs a decision_id or an action)")
    return err


def clean_draft(text, user=""):
    """(text, dropped): the draft as it would be posted and the lines removed from it. Only marked meta lines at the
    start or end are removed, plus a trailing rule block that is empty or addresses the user. text is '' when nothing
    postable is left."""
    names = [n for n in ("alan", user.lower()) if n]
    lines = str(text or "").splitlines()
    dropped = []
    while lines and (not lines[0].strip() or META_LINE.match(lines[0])):
        dropped.append(lines.pop(0))
    while lines and (not lines[-1].strip() or META_LINE.match(lines[-1])):
        dropped.insert(0, lines.pop())
    rules = [i for i, l in enumerate(lines) if RULE.match(l)]
    if rules and any(l.strip() for l in lines[:rules[-1]]):
        tail = lines[rules[-1] + 1:]
        if not any(l.strip() for l in tail) or any(re.search(rf"\b{re.escape(n)}\b", l, re.I) for l in tail for n in names):
            dropped = lines[rules[-1]:] + dropped
            lines = lines[:rules[-1]]
    while lines and (not lines[-1].strip() or META_LINE.match(lines[-1])):
        dropped.insert(0, lines.pop())
    return "\n".join(lines).strip(), [l for l in dropped if l.strip()]


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "x"


def row_drafts(r, x, ref, url, user, warnings):
    """Unposted drafts of a row (its `drafts` boxes, else its single draft text) as feed drafts, cleaned; each dropped
    line is reported in `warnings`."""
    out = []

    def clean(text, did):
        text, dropped = clean_draft(text, user)
        warnings.extend(f"{ref} draft {did}: dropped line {l.strip()!r}" for l in dropped)
        return text

    for d in x.get("drafts") or []:
        if d.get("posted_at"):
            continue
        text = clean(d.get("text"), d["id"])
        if text:
            out.append({"id": d["id"], "target": d["target"], "target_url": d.get("target_url", url), "text": text})
    if not out and not x.get("decided"):
        text = clean(r.draft_text(x), "draft")
        if text:
            out.append({"id": "draft", "target": ref, "target_url": url, "text": text})
    return out


def row_actions(r, x, ref, rid, user, sidecar):
    """Buttons for a row (decision options excluded, they sit on the decision card), with ids a click can name."""
    wtf, never = r.standard_actions(x, ref)
    real = [a for a in r.real_actions(x, ref, user) if not a.get("_opt")]
    if not real and not (x.get("decision") and not x.get("decided")) and not x.get("_dptr"):
        raise ValueError(f"{ref}: row without a real action cannot go into the feed")
    out, seen = [], {}
    for a in real + [wtf, never]:
        s = slug(a["label"])
        n = seen[s] = seen.get(s, 0) + 1
        aid = f"{rid}.{s}" + (f"-{n}" if n > 1 else "")
        out.append({"id": aid, "label": a["label"], "outward": bool(a.get("outward"))})
        sidecar[aid] = {"label": a["label"], "target": ref, "outward": bool(a.get("outward")), "prompt": a["prompt"]}
    return out


def plain(html_text):
    import html as h
    return re.sub(r"\s+", " ", h.unescape(re.sub(r"<[^>]+>", " ", html_text or ""))).strip()


def row_decision(r, x, ref, rid, url, did, sidecar):
    d = x["decision"]
    opts = []
    for o in d["options"]:
        aid = f"{rid}.opt-{slug(o['label'])}"
        opts.append({"label": o["label"], "consequence": o["consequence"], "action_id": aid, "outward": bool(o.get("outward"))})
        sidecar[aid] = {"label": o["label"], "target": ref, "outward": bool(o.get("outward")), "prompt": o["prompt"]}
    rec = next((o["label"] for o in d["options"] if o.get("recommended")), d["options"][0]["label"] if len(d["options"]) == 1 else "")
    project = r.PROJECTS.get(ref.split()[0].lower(), "") if "!" in ref else ""
    return {"id": did, "title": d["question"], "project": project, "why_now": x.get("why") or plain(x.get("next", "")),
            "options": opts, "recommendation": rec, "links": [url] if url else [], "urgent": bool(x.get("urgent"))}


def split_toon_row(line):
    """One TOON table row: comma separated, "quoted" cells with \\n, \\" and \\\\ escapes."""
    cells, cur, i, quoted = [], [], 0, False
    line = line.strip()
    while i < len(line):
        c = line[i]
        if quoted and c == "\\" and i + 1 < len(line):
            i += 1
            cur.append({"n": "\n", "t": "\t"}.get(line[i], line[i]))
        elif c == '"':
            quoted = not quoted
        elif c == "," and not quoted:
            cells.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    return cells + ["".join(cur)]


SECTION = re.compile(r"(?m)^(Why now|Options|Recommendation|Links):\s*")


def parse_reason(reason):
    """A captain-hold reason as sections: the text before the first label is the context, then Why now, Options, Recommendation, Links."""
    parts = SECTION.split(reason)
    sections = {"context": parts[0].strip()}
    sections.update({parts[i]: parts[i + 1].strip() for i in range(1, len(parts) - 1, 2)})
    return sections


def options_segment(reason):
    """The free-text options part of a hold reason ('options - a, or b; recommendation ...'), or ''."""
    m = re.search(r"\boptions?\b\s*[:\-]?\s*(.*?)(?=\brecommendation\s*[:\-]|\brecommended\s*[:\-]|\bwhy now\b|$)", reason, re.I | re.S)
    return m.group(1).strip() if m else ""


def option_chunks(text):
    """Split an options text into choices; tries the formats firstmate cards use, needs at least two."""
    text = (text or "").strip()
    for pat in (r"\((?:\d|[a-h])\)\s*", r"\boption\s+\d+\s*", r"(?:^|(?<=[;,.]\s))\d\s+", r";\s*(?:or\s+)?", r",?\s+or\s+", r"\s+-\s+"):
        parts = re.split(pat, text, flags=re.I)
        if pat.startswith((r"\((", r"\boption", r"(?:^")) and parts and not re.match(pat, text, re.I):
            parts = parts[1:]  # text before the first marker is context, not a choice
        parts = [re.sub(r"^\d+[).,:]?\s+", "", p).strip(" ;,.-") for p in parts]
        parts = [p for p in parts if len(p) > 3]
        if 2 <= len(parts) <= 5:
            return parts
    return []


def card_head(reason):
    """(title, summary, rest) from the captain-hold-lifecycle card shape: a 'Title:' line, a 'Summary:' block of '- Heading: text' lines."""
    lines, title, summary, i = reason.replace("\\n", "\n").split("\n"), "", [], 0
    if lines and lines[0].startswith("Title:"):
        title, i = lines[0][6:].strip(), 1
    if i < len(lines) and lines[i].strip() == "Summary:":
        i += 1
        while i < len(lines):
            m = re.match(r"^- ([^:]+):\s*(.+)$", lines[i].strip())
            if not m:
                break
            summary.append({"heading": m.group(1).strip(), "text": m.group(2).strip()})
            i += 1
    return title, summary, "\n".join(lines[i:]).strip()


# Legacy captain-hold reasons are one string: "What and where: ... Why now: ... Options: (a) ... (b) ... Recommendation: ... Detail: <paths>".
LEGACY_LABEL = re.compile(r"(?:(?<=^)|(?<=[.!?)]\s)|(?<=\n))(What and where|Why now|Options|Recommendation|Detail|Links):\s*")
PATH_RE = re.compile(r"(?<![\w:/])/(?:Users|private|tmp|var|Library|Volumes)/[^\s,;)]*")
MR_URL = re.compile(r"https://[^\s/]+/(?:[\w.-]+/)*?([\w.-]+)/-/merge_requests/(\d+)")


def legacy_sections(text):
    """[(label, text)] in order when the reason carries at least two of the labels inline, else []."""
    parts = LEGACY_LABEL.split(text.replace("\\n", "\n").strip())
    out = [(parts[i], parts[i + 1].strip()) for i in range(1, len(parts) - 1, 2)]
    return out if len(out) >= 2 else []


def short_text(text):
    """Readable summary text: GitLab MR links as 'repo !N', local file paths removed."""
    text = MR_URL.sub(lambda m: f"{m.group(1)} !{m.group(2)}", text)
    text = re.sub(r"\b([\w.-]+) (?:merge request|MR) \1 !", r"\1 !", text)
    text = re.sub(r"^\(([a-h])\)", lambda m: m.group(1).upper(), text)
    text = PATH_RE.sub("", text)
    text = re.sub(r"\(\s*\)|\band the card on today's [^.]*", "", text)
    text = re.sub(r"\s+([.,;])(?=\s|$)", r"\1", re.sub(r"[ \t]{2,}", " ", text)).strip(" ,;")
    return text[:1].upper() + text[1:]


def legacy_title(what, row_title, rid):
    """A readable title for a legacy card: the row's own when it is not the task id, else the MR plus its parenthesis, else the first clause."""
    if row_title and row_title != rid and " " in row_title:
        return row_title
    m = MR_URL.search(what)
    ref = f"{m.group(1)} !{m.group(2)}" if m else ""
    paren = re.search(r"\(([^()]{8,100})\)", MR_URL.sub("", what))
    if ref and paren:
        t = paren.group(1).strip()
        return f"{ref}: {t[:1].upper() + t[1:]}"
    clause = re.sub(r"^(decide|choose|confirm)\s+(what to do with|whether to|whether|where|how to|if)?\s*", "", short_text(what), flags=re.I)
    clause = re.split(r"[.;]", clause)[0].strip()
    clause = (clause[:80].rsplit(" ", 1)[0] if len(clause) > 80 else clause) or rid
    return clause[:1].upper() + clause[1:]


def legacy_card(full, row_title, rid):
    """(title, summary parts, sections dict) for a legacy reason, or None when it is not in the labelled shape."""
    secs = legacy_sections(full)
    if not secs:
        return None
    by = {}
    for label, text in secs:
        by.setdefault(label, text)
    parts = []
    for label in ("What and where", "Why now", "Options", "Recommendation"):
        text = by.get(label)
        if not text:
            continue
        if label == "Options":
            chunks = option_chunks(text)
            text = "\n".join(f"{chr(65 + i)}. {short_text(c)}" for i, c in enumerate(chunks)) if chunks else short_text(text)
        else:
            text = short_text(text)
        if text:
            parts.append({"heading": label, "text": text})
    return legacy_title(by.get("What and where", ""), row_title, rid), parts, by


def hold_decision(row):
    """A firstmate captain-hold task (tasks-axi list row) as a feed decision."""
    full = row.get("hold_reason") or ""
    card_title, summary, reason = card_head(full)
    s = parse_reason(reason)
    legacy = None if card_title or summary else legacy_card(full, row.get("title"), row["id"])
    if legacy:
        card_title, summary, by = legacy
        s = {"context": by.get("What and where", ""), "Why now": short_text(by.get("Why now", "")), "Options": by.get("Options", ""),
             "Recommendation": by.get("Recommendation", ""), "Links": by.get("Links", "")}
        reason = by.get("Options", "")
    opts = []
    chunks = option_chunks(s.get("Options", "")) or option_chunks(options_segment(reason)) or option_chunks(reason)
    for i, c in enumerate(chunks, 1):
        label = re.split(r" - |(?<!\d):(?!\d)|;| \(|, ", c, maxsplit=1)[0].strip()
        label = " ".join(label.split()[:8])[:80]
        if len(label) < 3:  # schema needs a real label; fall back to the choice's own first words
            label = " ".join(c.split()[:8])[:80]
        if len(label) < 3:
            continue
        opts.append({"label": label, "consequence": c, "action_id": f"{row['id']}.opt-{i}", "outward": False})
    rec = re.split(r"(?<=[.!?])\s", short_text(s.get("Recommendation", "")) if legacy else s.get("Recommendation", ""), maxsplit=1)[0]
    if not opts and rec:
        opts.append({"label": "Do the recommendation", "consequence": rec, "action_id": f"{row['id']}.opt-rec", "outward": False})
    # Defer and Drop are on every card, after the specific choices; "standard" lets the app draw them smaller.
    opts += [{"label": "Defer one week", "consequence": "Keep it held and bring it back in 7 days.", "action_id": f"{row['id']}.opt-defer", "outward": False, "standard": True},
             {"label": "Drop it", "consequence": "Close it as no longer needed; nothing changes outside firstmate.", "action_id": f"{row['id']}.opt-drop", "outward": False, "standard": True}]
    links = [u.rstrip(".,;)") for u in re.findall(r"https?://[^\s,)]+", s.get("Links", "") or reason)]
    repo = row.get("repo") or ""
    extra = {"summary": summary[:4]} if 2 <= len(summary) <= 4 else {}
    extra["full_context"] = full.replace("\\n", "\n").strip()
    return {**extra, "id": row["id"], "title": card_title or row.get("title") or row["id"], "project": "" if repo in ("-", "") else repo,
            "why_now": s.get("Why now") or s["context"].split("\n")[0], "options": opts, "recommendation": rec,
            "links": list(dict.fromkeys(links)), "urgent": str(row.get("priority", "")).lower() in URGENT,
            "created_at": row.get("created") or ""}


def parse_holds(text):
    """Holds from a command's stdout: JSON (a list of feed decisions, or {"decisions": [...]}) or a tasks-axi TOON list."""
    text = text.strip()
    if text[:1] in "[{":
        data = json.loads(text)
        return data["decisions"] if isinstance(data, dict) else data
    rows, fields = [], None
    for line in text.splitlines():
        m = re.match(r"^\w+\[\d+\]\{([^}]*)\}:\s*$", line)
        if m:
            fields = m.group(1).split(",")
        elif line and not line.startswith(" "):
            fields = None
        elif fields and line.strip():
            # tasks-axi cuts long cells and appends a tool hint; keep the text, drop the hint.
            cells = [re.sub(r"(?:\\n|\n)\.\.\. \(truncated, \d+ chars total - use show [^)]*\)", "…", c) for c in split_toon_row(line)]
            rows.append(hold_decision(dict(zip(fields, cells))))
    return rows


def load_holds(cmd, timeout=60):
    """Decisions held for the captain, read only through the configured firstmate read command (no shell, no home path here)."""
    if not cmd:
        return []
    r = subprocess.run(shlex.split(cmd), capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"holds command failed ({r.returncode}): {r.stderr.strip()[:200]}")
    return parse_holds(r.stdout)


def build(r, b, t, m, dec, user, holds=(), producer="linear-action-board", now=None):
    """(feed, sidecar): the companion-feed.v1 dict and {action_id: {label, target, outward, prompt}} for firstmate's click handling."""
    sidecar, decisions, did_by_ref, warnings, base = {}, [], {}, [], b.get("linear_url_base", LINEAR_BASE)
    rows = [(x, x["id"], "t") for x in t] + [(x, x["refs"][0][1], "mr") for x in m] + [(x, x["id"], "d") for x in dec]
    for x, ref, kind in rows:
        url = x["refs"][0][0] if kind == "mr" else base + ref if kind == "t" else ""
        if x.get("decision") and not x.get("decided"):
            did_by_ref[ref] = r.task_key(x)
            decisions.append(row_decision(r, x, ref, r.slug(kind, ref), url, did_by_ref[ref], sidecar))
    mrs, tickets = [], []
    for x, ref, kind in rows:
        rid = r.slug(kind, ref)
        did = did_by_ref.get(ref) or did_by_ref.get((x.get("_dptr") or {}).get("ref"))
        extra = {"decision_id": did} if did and not x.get("decided") else {}
        if kind == "d":
            continue
        if kind == "mr":
            if x["verdict"] not in r.VERDICTS:
                raise ValueError(f"{ref}: bad verdict {x['verdict']!r}")
            fact, ms, url = x.get("_fact") or {}, x.get("merge_state") or {}, x["refs"][0][0]
            threads = len(fact["open_threads"]) if "open_threads" in fact else ms.get("open_threads")
            mrs.append({"ref": ref, "url": url, "title": x.get("title") or (x["refs"][0][2] if len(x["refs"][0]) > 2 else x.get("what", "")),
                        "role": "author" if r.own_mr(x, user) else "reviewer", "verdict": x["verdict"], "label": x.get("label", ""),
                        "next_owner": x.get("owner", "You"), "pipeline": (fact.get("head_pipeline") or {}).get("status") or ms.get("pipeline"),
                        "open_threads": threads, "drafts": row_drafts(r, x, ref, url, user, warnings),
                        "actions": row_actions(r, x, ref, rid, user, sidecar),
                        # Card context (optional fields): who wrote it, what blocks it, the next step, ticket, last activity.
                        "author": x.get("author") or (fact.get("author") or {}).get("username") or "",
                        "headline": plain(x.get("headline", "")), "blocker": plain(x.get("why", "")), "next": plain(x.get("next", "")),
                        "ticket": str(x.get("ticket") or ""), "updated_at": fact.get("updated_at") or ms.get("updated_at") or "",
                        **extra})
        else:
            step, owner = r.finish_parts(x)
            named = {r.norm(n, "mr") for n in ([x["mr"]] if isinstance(x.get("mr"), str) else x.get("mr") or [])}
            linked = [y["refs"][0][1] for y in m if x["id"].upper() in r.mr_steps.mr_ticket_ids(y)
                      or str(y.get("ticket", "")).upper() == x["id"].upper() or any(r.norm(q[1], "mr") in named for q in y["refs"])]
            tickets.append({"identifier": ref, "url": base + ref, "title": x.get("title") or x.get("what", ""),
                            "status": x.get("status", ""), "finish": {"step": step, "owner": "You" if owner.lower() in r.SELF else owner},
                            "linked_mrs": linked, "actions": row_actions(r, x, ref, rid, user, sidecar), **extra})
    seen = {d["id"] for d in decisions}
    decisions += [h for h in holds if h["id"] not in seen]
    when = (now or datetime.now(timezone.utc)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    feed = {"schema": "companion-feed.v1", "generated_at": when, "producer": producer,
            "decisions": decisions, "mrs": mrs, "tickets": tickets}
    warnings = [str(w) for w in b.get("feed_warnings") or []] + warnings
    if warnings:
        feed["warnings"] = warnings
    errors = validate(feed, load_schema("companion-feed.v1"))
    if errors:
        raise ValueError("feed does not match companion-feed.v1: " + "; ".join(errors[:5]))
    return feed, sidecar


def write_atomic(path, data):
    """Write JSON to a temp file beside `path`, then rename: a reader never sees half a file."""
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=1)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def write(path, feed, sidecar, actions_out=None):
    """Write the feed and, beside it (or at actions_out), the action prompts firstmate maps clicks to. The feed holds no prompts."""
    p = Path(path).expanduser()
    write_atomic(p, feed)
    write_atomic(actions_out or p.with_name(p.stem + ".actions.json"),
                 {"schema": "companion-actions.v1", "generated_at": feed["generated_at"], "actions": sidecar})
