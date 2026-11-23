"""Age label on the board's own analysis text, and the feed warning."""
import sys, unittest
from datetime import date
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
__import__("os").environ["SHIPDECK_ORG_CONFIG"] = str(Path(__file__).resolve().with_name("org.test.json"))  # hermetic org values
import refresh

BOARD = {"date": "2026-11-02", "mrs": [{"refs": [["https://gitlab.com/g/x/-/merge_requests/42", "obs !42"]]}], "tickets": [{"id": "IN-2758"}]}


def feed():
    return {"warnings": ["MR facts not refreshed: x"],
            "mrs": [{"ref": "obs !42", "verdict": "notyet", "next": "Change both YAML files."}, {"ref": "obs !103", "next": "Fresh card from a report."}],
            "tickets": [{"identifier": "IN-2758", "finish": {"step": "Merge !2023", "owner": "You"}}, {"identifier": "IN-9", "finish": {"step": "x", "owner": "y"}}]}


class AnalysisAge(unittest.TestCase):
    def test_old_board_text_gets_its_date_and_one_warning(self):
        f = refresh.label_analysis_age(feed(), BOARD, today=date(2026, 11, 10))
        self.assertEqual(f["mrs"][0]["next"], "Analysed 2 Nov: Change both YAML files.")
        self.assertEqual(f["mrs"][0]["verdict"], "notyet")  # verdicts are never rewritten
        self.assertEqual(f["mrs"][1]["next"], "Fresh card from a report.")  # not from the board
        self.assertEqual(f["tickets"][0]["finish"]["step"], "Analysed 2 Nov: Merge !2023")
        self.assertEqual(f["tickets"][1]["finish"]["step"], "x")
        self.assertEqual(f["warnings"], ["MR facts not refreshed: x", "Card analysis is 8 days old (board 2026-11-02)"])

    def test_running_twice_does_not_stack_labels_or_warnings(self):
        f = refresh.label_analysis_age(refresh.label_analysis_age(feed(), BOARD, today=date(2026, 11, 3)), BOARD, today=date(2026, 11, 3))
        self.assertEqual(f["mrs"][0]["next"], "Analysed 2 Nov: Change both YAML files.")
        self.assertEqual([w for w in f["warnings"] if w.startswith("Card analysis")], ["Card analysis is 1 day old (board 2026-11-02)"])

    def test_todays_board_or_no_date_changes_nothing(self):
        for board, today in ((BOARD, date(2026, 11, 2)), ({**BOARD, "date": "not a date"}, date(2026, 11, 10)), ({k: v for k, v in BOARD.items() if k != "date"}, date(2026, 11, 10))):
            f = refresh.label_analysis_age(feed(), board, today=today)
            self.assertEqual(f, feed())


if __name__ == "__main__":
    unittest.main()
