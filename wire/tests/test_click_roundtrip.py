"""Click round trip (test B), pipe side: clicks for sample feed cards, worker controls and Deck Officer comments go
through the real click pipe in temporary homes. The Swift ClickRoundTripTests use the same pipe with app-written clicks
and read completion through the command ledger and Deck Officer reply files.
"""
import json, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
from click_roundtrip import roundtrip

FEEDS = Path(__file__).resolve().parent.parent / "fixtures" / "feeds"
SAMPLES = ["producer", "edge-cases", "shipdeck-skill"]
WORKER_PROMPTS = {
    "worker.sweep": "record its report as delivered",
    "worker.cleanup": "Refuse when the worker has unposted work",
    "worker.discard": "Run fm-teardown.sh with its discard option",
    "worker.merge": "Merge this worker's result under the usual merge authority gates",
    "worker.steer": "Send the text below to this worker with fm-send.sh",
}


def app_clicks(doc):
    """[(click, expected)] for every button, with the app's id rules: an option sends its action_id, a free answer
    `<decision>.answer`, Add context `<ref>.add-context`, a review draft its own `<row>.comment-<draft>` action with the
    draft text, MR and ticket row buttons their action id with the MR ref or ticket identifier as target."""
    out = []
    for d in doc["decisions"]:
        for index, o in enumerate(d["options"]):
            out.append(({"action_id": o["action_id"], "target": d["id"],
                         "selected_option": {"label": o["label"], "consequence": o["consequence"], "index": index}}, ("option", d, o)))
        out.append(({"action_id": d["id"] + ".answer", "target": d["id"], "draft_text": "Free answer text"}, ("answer", d, None)))
        out.append(({"action_id": d["id"] + ".add-context", "target": d["id"], "draft_text": "Context for the decision"}, ("context", d, None)))
    for m in doc["mrs"]:
        for dr in m["drafts"]:
            a = next((a for a in m["actions"] if a["id"].endswith(".comment-" + dr["id"])), None)
            if a:
                out.append(({"action_id": a["id"], "target": m["ref"], "draft_text": dr["text"]}, ("action", a, None)))
        out += [({"action_id": a["id"], "target": m["ref"]}, ("action", a, None)) for a in m["actions"] if ".comment-" not in a["id"]]
        out.append(({"action_id": m["ref"] + ".add-context", "target": m["ref"], "draft_text": "Context for the MR"}, ("context", m, None)))
    for t in doc["tickets"]:
        out += [({"action_id": a["id"], "target": t["identifier"]}, ("action", a, None)) for a in t["actions"]]
        out.append(({"action_id": t["identifier"] + ".add-context", "target": t["identifier"], "draft_text": "Context for the ticket"}, ("context", t, None)))
    for action, prompt in WORKER_PROMPTS.items():
        task = "running-worker" if action == "worker.steer" else "finished-worker"
        click = {"action_id": action, "target": f"worker:{task}"}
        if action == "worker.sweep":
            click["draft_text"] = "Verdict: all green"
        elif action == "worker.steer":
            click["draft_text"] = "Check the failing test"
        out.append((click, ("worker", task, prompt)))
    targets = ["global"] + [d["id"] for d in doc["decisions"]] + [m["ref"] for m in doc["mrs"]]
    targets += [t["identifier"] for t in doc["tickets"]]
    for target in targets:
        out.append(({"action_id": "comment_deck_officer", "target": target, "draft_text": f"Please check {target}"},
                    ("comment", target, None)))
    return out


def write_clicks(inbox, clicks):
    names = []
    for n, (c, _) in enumerate(clicks):
        key = f"click{n:04d}-roundtrip"
        name = f"1795000000-{key}.json"
        (inbox / name).write_text(json.dumps({"schema": "companion-click.v1", "idempotency_key": key, "created_at": "2026-11-19T12:00:00Z", **c}))
        names.append(name)
    return names


class ClickRoundTrip(unittest.TestCase):
    def test_every_button_type_reaches_its_work_item_and_is_answered(self):
        for sample in SAMPLES:
            feed_path, actions_path = FEEDS / f"{sample}.feed.json", FEEDS / f"{sample}.feed.actions.json"
            doc, side = json.loads(feed_path.read_text()), json.loads(actions_path.read_text())["actions"]
            clicks = app_clicks(doc)
            self.assertTrue(clicks)
            with tempfile.TemporaryDirectory() as tmp, self.subTest(sample=sample):
                inbox = Path(tmp)
                names = write_clicks(inbox, clicks)
                report = roundtrip(inbox, feed_path, actions_path)
                self.assertEqual((report["runs"], report["errors"]), ([0, 0, 0], ""))
                for name, (c, (kind, item, option)) in zip(names, clicks):
                    r = report["clicks"][name]
                    with self.subTest(action_id=c["action_id"], target=c["target"]):
                        self.assertTrue(r["filed"], "click never reached firstmate")
                        self.assertFalse(r["stale"], "the pipe could not map the click (dead button)")
                        home = "deck_officer" if kind == "comment" else "main"
                        self.assertEqual(r["note_homes"], [home])
                        self.assertIn(f"Target: {c['target']}", r["note"].splitlines())
                        if c["action_id"] in side:
                            self.assertEqual(r["note_head"], f"ShipDeck click: {side[c['action_id']]['label']}")
                            self.assertIn(side[c["action_id"]]["prompt"], r["note"])
                        elif kind == "option":
                            self.assertIn(f"Answer to decision {item['id']} ", r["note"])
                            self.assertIn(f"option '{option['label']}'", r["note"])
                        elif kind == "answer":
                            self.assertIn(f"Free answer to decision {item['id']}", r["note"])
                        elif kind == "worker":
                            self.assertIn(f"Worker click for task {item} (", r["note"])
                            self.assertIn(option, r["note"])
                        elif kind == "comment":
                            self.assertTrue(r["note_head"].startswith("ShipDeck comment for Deck Officer"))
                        else:
                            self.assertEqual(kind, "context")
                            self.assertIn(f"Add context on {c['target']}:", r["note"])
                        if c.get("draft_text"):
                            self.assertIn(c["draft_text"], r["note"])
                        self.assertEqual(r["states"], ["picked_up", "acknowledged", "done"])
                        self.assertEqual(r["reply"], "done")
                        key = Path(name).stem.partition("-")[2]
                        self.assertEqual(r["reply_text"], f"done: {home} {key}")
                        self.assertTrue(r["handled"], "the pipe moves a filed click to handled/")

    def test_a_click_the_pipe_cannot_map_is_answered_not_lost(self):
        feed_path, actions_path = FEEDS / "producer.feed.json", FEEDS / "producer.feed.actions.json"
        with tempfile.TemporaryDirectory() as tmp:
            inbox = Path(tmp)
            [name] = write_clicks(inbox, [({"action_id": "decision:board-mr-obs-42:option:0", "target": "board-mr-obs-42"}, None)])
            r = roundtrip(inbox, feed_path, actions_path)["clicks"][name]
            self.assertTrue(r["filed"] and r["stale"] and r["handled"])
            self.assertEqual(r["reply"], "done")


if __name__ == "__main__":
    unittest.main()
