import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import feed

REASON = ("What and where: decide what to do with services merge request https://gitlab.com/example-group/backend/services/-/merge_requests/5743 "
          "(trim the Docker context and stabilise the node_modules layer). Why now: main already ships the digest fix, so about 12 MB is left. "
          "Options: (a) close it with the drafted reply, so the 12 MB stays; (b) rewrite it as a small new merge request with a dist-only .dockerignore. "
          "Recommendation: (a), because trimming needs risky carve-outs. Detail: /Users/example/firstmate/data/ts5743-rework/replies.md and the card.")

class Legacy(unittest.TestCase):
    def d(self, reason=REASON, title="ts5743-rework"):
        return feed.hold_decision({"id": "ts5743-rework", "title": title, "hold_reason": reason, "repo": "-", "priority": "", "created": "2026-10-20"})
    def test_title_is_readable(self):
        self.assertEqual(self.d()["title"], "services !5743: Trim the Docker context and stabilise the node_modules layer")
    def test_sections_options_and_recommendation(self):
        d = self.d()
        self.assertEqual([p["heading"] for p in d["summary"]], ["What and where", "Why now", "Options", "Recommendation"])
        self.assertEqual(d["summary"][2]["text"].split("\n")[0], "A. Close it with the drafted reply, so the 12 MB stays")
        self.assertIn("dist-only .dockerignore", d["summary"][2]["text"])
        self.assertEqual([o["label"] for o in d["options"][:2]], ["close it with the drafted reply", "rewrite it as a small new merge request"])
        self.assertTrue(d["recommendation"].startswith("A, because"))
    def test_paths_only_in_full_context(self):
        d = self.d()
        self.assertFalse(any("/Users/" in p["text"] for p in d["summary"]))
        self.assertIn("/Users/example/firstmate/data/ts5743-rework/replies.md", d["full_context"])
    def test_titled_card_and_plain_reason_unchanged(self):
        d = self.d("Title: Real title\nSummary:\n- A: one\n- B: two\nWhy now: x. Options: (a) one; (b) two. Recommendation: (a).")
        self.assertEqual((d["title"], len(d["summary"])), ("Real title", 2))
        p = self.d("Just a plain sentence with no labels.", "Plain title here")
        self.assertEqual(p["title"], "Plain title here"); self.assertNotIn("summary", p)
    def test_time_in_option_does_not_cut_the_label(self):
        d = self.d("Why now: x. Options: (1) Tonight about 20:00 UTC, reload; (2) Same reload during the day. Recommendation: (1).")
        self.assertEqual(d["options"][0]["label"], "Tonight about 20:00 UTC")

if __name__ == "__main__":
    unittest.main()
