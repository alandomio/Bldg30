import json, os, shutil, subprocess, sys, tempfile, time, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import review_drafts as r, render

REPORT = Path(__file__).resolve().parent / "fixtures" / "rv-obs-101" / "report.md"
URL = "https://gitlab.com/example-group/ops/observability/-/merge_requests/101"


class ReviewDrafts(unittest.TestCase):
    def feed(self):
        return {"decisions": [], "mrs": [{"ref": "obs !42", "url": "https://gitlab.com/example-group/ops/observability/-/merge_requests/42", "drafts": [], "actions": []}]}

    def test_review_draft_subprocess_discovers_reports_under_the_wire_home(self):
        bin_dir = Path(__file__).resolve().parents[1] / "bin"
        child = "import json; from review_drafts import recent_reports; print(json.dumps([r['task'] for r in recent_reports()]))"
        launch = "import subprocess, sys, wire; subprocess.run([sys.executable, '-c', sys.argv[1]], check=True)"
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "data"
            task = data / REPORT.parent.name
            task.mkdir(parents=True)
            shutil.copyfile(REPORT, task / REPORT.name)
            env = {**os.environ, "SHIPDECK_WIRE_HOME": str(data / "shipdeck-wire")}
            env.pop("FM_HOME", None)
            result = subprocess.run([sys.executable, "-c", launch, child], cwd=bin_dir, env=env,
                                    capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout), ["rv-obs-101"])

    @unittest.skipUnless(REPORT.is_file(), "report not on this machine")
    def test_parse_keeps_full_text_placement_severity(self):
        rep = r.parse_report(REPORT)
        self.assertEqual([d["id"] for d in rep["drafts"]], ["f1", "f2", "f3"])
        self.assertEqual([d["severity"] for d in rep["drafts"]], ["required", "non-blocking", ""])
        self.assertEqual(rep["drafts"][0]["target"], "src/scheduler/plan.js:84")
        self.assertEqual(rep["drafts"][2]["target"], "General note")
        self.assertIn("Please describe both changes", rep["drafts"][2]["text"])

    @unittest.skipUnless(REPORT.is_file(), "report not on this machine")
    def test_card_created_with_one_action_per_draft_and_posted_ones_dropped(self):
        rep, feed, side = r.parse_report(REPORT), self.feed(), {}
        r.apply(feed, side, "/nonexistent", lambda u: "opened", render.standard_actions, notes_fn=lambda u: [], reports=[rep])
        row = feed["mrs"][0]
        self.assertEqual((row["ref"], len(row["drafts"])), ("obs !101", 3))
        self.assertTrue(all(a["id"] in side and side[a["id"]]["outward"] for a in row["actions"] if ".comment-" in a["id"]))
        feed2 = self.feed()
        r.apply(feed2, {}, "/nonexistent", lambda u: "opened", render.standard_actions, notes_fn=lambda u: [rep["drafts"][0]["text"]], reports=[rep])
        self.assertEqual([d["id"] for d in feed2["mrs"][0]["drafts"]], ["f2", "f3"])

    @unittest.skipUnless(REPORT.is_file(), "report not on this machine")
    def test_user_note_after_report_retires_its_drafts(self):
        rep = r.parse_report(REPORT)
        later = [{"body": "Reworded by hand", "author": "adomio", "at": rep["written"] + 60}]
        f = self.feed(); r.apply(f, {}, "/x", lambda u: "opened", render.standard_actions, notes_fn=lambda u: later, reports=[rep])
        self.assertEqual([m["ref"] for m in f["mrs"]], ["obs !42"])
        other = [dict(later[0], author="someone"), dict(later[0], at=rep["written"] - 60)]
        f = self.feed(); r.apply(f, {}, "/x", lambda u: "opened", render.standard_actions, notes_fn=lambda u: other, reports=[rep])
        self.assertEqual([len(m["drafts"]) for m in f["mrs"] if m["ref"] == "obs !101"], [3])

    @unittest.skipUnless(REPORT.is_file(), "report not on this machine")
    def test_closed_mr_unreadable_notes_and_decision(self):
        rep = r.parse_report(REPORT)
        f = self.feed(); r.apply(f, {}, "/x", lambda u: "merged", render.standard_actions, notes_fn=lambda u: [], reports=[rep])
        self.assertEqual([m["ref"] for m in f["mrs"]], ["obs !42"])
        f = self.feed(); r.apply(f, {}, "/x", lambda u: "opened", render.standard_actions, notes_fn=lambda u: None, reports=[rep])
        self.assertEqual([m["ref"] for m in f["mrs"]], ["obs !42"])
        f = self.feed(); f["decisions"] = [{"id": "d", "title": "Post review comments on obs 101", "full_context": f"report {REPORT}"}]
        r.apply(f, {}, "/x", lambda u: "merged", render.standard_actions, notes_fn=lambda u: [], reports=[])
        self.assertEqual(f["decisions"], [])  # nothing left to post on a merged MR
        f = self.feed(); f["decisions"] = [{"id": "d", "title": "Post review comments on obs 101", "full_context": f"report {REPORT}"}]
        r.apply(f, {}, "/x", lambda u: None, render.standard_actions, notes_fn=lambda u: [], reports=[])
        self.assertIn("Full text of the drafts:", f["decisions"][0]["full_context"])
        self.assertIn("Please describe both changes", f["decisions"][0]["full_context"])
        f = self.feed(); f["decisions"] = [{"id": "d", "title": "Post review comments on obs 101", "full_context": f"report {REPORT}"}]
        r.apply(f, {}, "/x", lambda u: "opened", render.standard_actions, notes_fn=lambda u: [], reports=[])
        self.assertEqual((f["decisions"], f["mrs"][0]["ref"]), ([], "obs !101"))


if __name__ == "__main__":
    unittest.main()


class TwoReportsSameMrTests(unittest.TestCase):
    def test_every_workers_drafts_stay_on_the_card_with_unique_ids(self):
        url = "https://gitlab.com/example-group/x/-/merge_requests/9"
        with tempfile.TemporaryDirectory() as tmp:
            for i, (task, text) in enumerate([("rv-x-9", "First finding here"), ("rv-x-9b", "Second finding here")]):
                d = Path(tmp) / task
                d.mkdir()
                (d / "report.md").write_text(f"# Review: x !9, t\n\nMR: {url}\n\nVerdict: no.\n\n## Comment drafts\n\nplacement: general\n```\n{text}\n```\n")
                os.utime(d / "report.md", (time.time() - i, time.time() - i))
            reps = r.recent_reports(data=tmp)
        self.assertEqual({x["task"] for x in reps}, {"rv-x-9", "rv-x-9b"})
        self.assertEqual(len({d["id"] for x in reps for d in x["drafts"]}), 2)


class SourceTaskTests(unittest.TestCase):
    @unittest.skipUnless(REPORT.is_file(), "report not on this machine")
    def test_drafts_name_the_worker_task_whose_report_they_came_from(self):
        rep = r.parse_report(REPORT)
        self.assertEqual(rep["task"], "rv-obs-101")
        row = r.build_row({}, rep, "obs !101", "hold", {}, render.standard_actions)
        self.assertTrue(row["drafts"] and all(d["source"] == "rv-obs-101" for d in row["drafts"]))
