import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import approvals as a

def note(who, body="x", system=False, at="2026-11-01T11:46:02Z", resolvable=True, resolved=False):
    return {"author": {"username": who}, "body": body, "system": system, "created_at": at, "resolvable": resolvable and not system, "resolved": resolved}

class Waiting(unittest.TestCase):
    def test_author_only_thread_does_not_wait_on_me(self):
        self.assertFalse(a.waits_on_user([{"notes": [note("rkim")]}], "adomio", "rkim"))
    def test_other_reviewer_replying_in_my_thread_waits_on_me(self):
        self.assertTrue(a.waits_on_user([{"notes": [note("adomio"), note("jdoe")]}], "adomio", "rkim"))
    def test_mention_by_someone_else_waits_on_me(self):
        self.assertTrue(a.waits_on_user([{"notes": [note("jdoe", "@adomio can you look")]}], "adomio", "rkim"))
    def test_author_reply_to_my_thread_does_not(self):
        self.assertFalse(a.waits_on_user([{"notes": [note("adomio"), note("rkim", "fixed")]}], "adomio", "rkim"))
    def test_resolved_thread_does_not(self):
        self.assertFalse(a.waits_on_user([{"notes": [note("adomio", resolved=True), note("jdoe", resolved=True)]}], "adomio", "rkim"))

class Fake:
    def __init__(self, approved, approve_at, commit_at, threads, left=0):
        self.map = {"/approvals": {"approved_by": [{"user": {"username": u}} for u in approved], "approvals_left": left},
                    "/notes": [note("adomio", "approved this merge request", True, approve_at)] if approve_at else [],
                    "/commits": [{"created_at": commit_at, "id": "abc123"}], "/discussions": threads}
    def __call__(self, cmd, capture_output, text):
        path = cmd[-1].split("/merge_requests/1", 1)[1]
        key = next(k for k in self.map if path.startswith(k))
        import json, types
        return types.SimpleNamespace(returncode=0, stdout=json.dumps(self.map[key]))

URL = "https://gitlab.com/g/p/-/merge_requests/1"

class Approval(unittest.TestCase):
    def test_approved_at_head_no_thread_waits_on_author(self):
        r = a.approval(URL, "adomio", "rkim", Fake(["jdoe", "adomio"], "2026-11-01T11:46:02Z", "2026-10-30T22:24:19+00:00", [{"notes": [note("rkim")]}]))
        self.assertEqual((r["approved_by"], r["approved_by_me"], r["at_head"], r["waiting_on"]), (["jdoe"], True, True, "rkim"))
    def test_new_commit_after_approval_brings_it_back(self):
        r = a.approval(URL, "adomio", "rkim", Fake(["adomio"], "2026-11-01T11:46:02Z", "2026-11-02T08:00:00+00:00", [], left=1))
        self.assertEqual((r["at_head"], r["waiting_on"]), (False, ""))
    def test_addressed_again_brings_it_back(self):
        r = a.approval(URL, "adomio", "rkim", Fake(["adomio"], "2026-11-01T11:46:02Z", "2026-10-30T00:00:00+00:00", [{"notes": [note("jdoe", "@adomio ping")]}]))
        self.assertEqual(r["waiting_on"], "")
    def test_not_approved_by_me(self):
        r = a.approval(URL, "adomio", "rkim", Fake(["jdoe"], None, "2026-10-30T00:00:00+00:00", [], left=1))
        self.assertEqual((r["approved_by_me"], r["waiting_on"]), (False, ""))
    def test_other_approved_no_approvals_left_waits_on_author_without_my_approval(self):
        r = a.approval(URL, "adomio", "Riley Kim (rkim)", Fake(["jdoe"], None, "2026-10-30T00:00:00+00:00", [], left=0))
        self.assertEqual((r["approved_by"], r["approved_by_me"], r["waiting_on"]), (["jdoe"], False, "rkim"))
        self.assertEqual(a.approved_label(r, "rkim"), "Approved by jdoe · 0 left · waiting on rkim to merge")
    def test_label_says_you_only_when_i_approved(self):
        r = a.approval(URL, "adomio", "rkim", Fake(["adomio", "jdoe"], "2026-11-01T11:46:02Z", "2026-10-30T00:00:00+00:00", []))
        self.assertEqual(a.approved_label(r, "rkim"), "Approved by you, jdoe · 0 left · waiting on rkim to merge")
    def test_no_approval_at_all_never_waits(self):
        self.assertEqual(a.approval(URL, "adomio", "rkim", Fake([], None, "2026-10-30T00:00:00+00:00", [], left=0))["waiting_on"], "")
    def test_thread_waiting_on_me_keeps_it_with_me_even_with_none_left(self):
        r = a.approval(URL, "adomio", "rkim", Fake(["jdoe"], None, "2026-10-30T00:00:00+00:00", [{"notes": [note("adomio"), note("jdoe")]}], left=0))
        self.assertEqual(r["waiting_on"], "")
    def test_my_own_mr_with_none_left_is_mine_to_merge(self):
        r = a.approval(URL, "adomio", "you", Fake(["rkim"], None, "2026-10-30T00:00:00+00:00", [], left=0))
        self.assertEqual(r["waiting_on"], "")
    def test_head_sha_is_reported(self):
        self.assertEqual(a.approval(URL, "adomio", "rkim", Fake(["jdoe"], None, "2026-10-30T00:00:00+00:00", [], left=1))["head_sha"], "abc123")
    def test_own_mr_never_waits(self):
        self.assertEqual(a.approval(URL, "adomio", "adomio", Fake(["adomio"], "2026-11-01T11:46:02Z", "2026-10-30T00:00:00+00:00", []))["waiting_on"], "")

if __name__ == "__main__":
    unittest.main()
