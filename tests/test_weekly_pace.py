import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "Sources" / "WeeklyPace.swift"]

HARNESS = """
import Foundation

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    print(String(data: data, encoding: .utf8)!)
}

func date(_ value: Any?) -> Date? {
    (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
}

func int(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

let request = try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: CommandLine.arguments[1])!) as! [String: Any]
let now = date(request["now"])!
let reset = date(request["reset"])
var result: [String: Any] = [:]
switch request["call"] as! String {
case "fraction":
    result["value"] = WeeklyPace.fraction(resetsAt: reset, now: now) ?? NSNull()
case "percent":
    result["value"] = WeeklyPace.percent(resetsAt: reset, now: now, reported: (request["reported"] as? NSNumber)?.doubleValue) ?? NSNull()
case "standing":
    result["value"] = WeeklyPace.standing(remainingPercent: int(request["remaining"]), pacePercent: int(request["pace"]))?.rawValue ?? NSNull()
case "rowText":
    result["value"] = WeeklyPace.rowText(int(request["pace"])!, turkish: request["turkish"] as! Bool)
case "summary":
    let accounts = (request["accounts"] as! [[String: Any]]).map { account in
        WeeklyPace.Account(name: account["name"] as! String, rows: (account["rows"] as! [[String: Any]]).map {
            WeeklyPace.Row(label: $0["label"] as! String, remainingPercent: int($0["remaining"]), pacePercent: int($0["pace"]))
        })
    }
    let summary = WeeklyPace.summary(accounts)
    func describe(_ entries: [WeeklyPace.Entry]) -> [[String: Any]] {
        entries.map { ["name": $0.name, "gap": $0.gap, "rows": $0.rows.map { row in row.label },
                       "tip": WeeklyPace.entryToolTip($0, turkish: false), "tipTurkish": WeeklyPace.entryToolTip($0, turkish: true)] }
    }
    result["value"] = ["behind": describe(summary.behind), "ahead": describe(summary.ahead)]
default:
    exit(2)
}
emit(result)
"""

NOW = 1_792_100_000
DAY = 86_400


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class WeeklyPaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="weekly-pace-test."))
        (cls.work / "main.swift").write_text(HARNESS)
        cls.binary = cls.work / "harness-bin"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.work / "main.swift"), "-o", str(cls.binary)],
            check=True,
            capture_output=True,
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, ignore_errors=True)

    def call(self, call, **arguments):
        path = self.work / "request.json"
        path.write_text(json.dumps({"call": call, "now": NOW, **arguments}))
        result = subprocess.run([str(self.binary), str(path)], check=True, capture_output=True, text=True)
        return json.loads(result.stdout)["value"]

    def fraction(self, reset):
        return self.call("fraction", reset=reset)

    def percent(self, reset, reported=None):
        return self.call("percent", reset=reset, reported=reported)

    def test_pace_is_the_share_of_the_week_passed(self):
        # Day 3 of 7: the reset is 4 days away.
        self.assertAlmostEqual(self.fraction(NOW + 4 * DAY), 3 / 7)
        self.assertEqual(self.percent(NOW + 4 * DAY), 43)
        self.assertEqual(self.percent(NOW + DAY), 86)
        self.assertEqual(self.percent(NOW + 60), 100)

    def test_reset_seven_days_away_is_the_start_of_the_week(self):
        self.assertEqual(self.fraction(NOW + 7 * DAY), 0)
        self.assertEqual(self.percent(NOW + 7 * DAY), 0)
        # A reset further away than a week (clock skew) clamps to the start too.
        self.assertEqual(self.fraction(NOW + 9 * DAY), 0)
        self.assertEqual(self.percent(NOW + 9 * DAY), 0)

    def test_reset_in_the_past(self):
        # The formula clamps to a full week...
        self.assertEqual(self.fraction(NOW - 60), 1)
        self.assertEqual(self.fraction(NOW - 3 * DAY), 1)
        self.assertEqual(self.fraction(NOW), 1)
        # ...but a row whose reset has passed shows a fresh week with an unknown reset: no pace.
        self.assertIsNone(self.percent(NOW - 60))
        self.assertIsNone(self.percent(NOW))
        self.assertIsNone(self.percent(NOW - 60, reported=0.5))

    def test_missing_reset(self):
        self.assertIsNone(self.fraction(None))
        self.assertIsNone(self.percent(None))

    def test_reported_pace_wins_when_it_is_a_fraction(self):
        self.assertEqual(self.percent(NOW + 4 * DAY, reported=0.34), 34)
        self.assertEqual(self.percent(None, reported=0.5), 50)
        self.assertEqual(self.percent(NOW + 4 * DAY, reported=0), 0)
        self.assertEqual(self.percent(NOW + 4 * DAY, reported=1), 100)
        # Not a fraction (a percentage, or a negative): the reset time decides.
        self.assertEqual(self.percent(NOW + 4 * DAY, reported=34), 43)
        self.assertEqual(self.percent(NOW + 4 * DAY, reported=-0.2), 43)
        self.assertIsNone(self.percent(None, reported=34))

    def standing(self, remaining, pace):
        return self.call("standing", remaining=remaining, pace=pace)

    def test_standing_against_the_pace(self):
        # The rows show what is left: 93% left is 7% used, 27 points under a 34% pace.
        self.assertEqual(self.standing(93, 34), "behind")
        self.assertEqual(self.standing(81, 34), "behind")  # 19% used: exactly 15 under
        self.assertEqual(self.standing(80, 34), "even")    # 20% used: 14 under
        self.assertEqual(self.standing(66, 34), "even")
        self.assertEqual(self.standing(52, 34), "even")    # 48% used: 14 over
        self.assertEqual(self.standing(51, 34), "ahead")   # 49% used: exactly 15 over
        self.assertEqual(self.standing(0, 50), "ahead")
        self.assertIsNone(self.standing(None, 34))
        self.assertIsNone(self.standing(93, None))

    def test_row_text(self):
        self.assertEqual(self.call("rowText", pace=34, turkish=False), "· pace 34%")
        self.assertEqual(self.call("rowText", pace=34, turkish=True), "· tempo 34%")

    def summary(self, *accounts):
        return self.call("summary", accounts=list(accounts))

    @staticmethod
    def account(name, weekly=None, fable=None, pace=43, fable_pace=None):
        rows = [{"label": "Weekly", "remaining": weekly, "pace": pace}]
        if fable is not None:
            rows.append({"label": "Fable", "remaining": fable, "pace": pace if fable_pace is None else fable_pace})
        return {"name": name, "rows": rows}

    def test_summary_splits_the_accounts_behind_and_ahead_of_their_pace(self):
        result = self.summary(
            self.account("chief", weekly=81, fable=80),     # 19% / 20% used vs 43%: behind by 24 and 23
            self.account("trossard", weekly=52, fable=35),  # weekly on pace, Fable 65% used: ahead by 22
            self.account("vlahovic", weekly=88, fable=90, pace=57),  # behind by 45 and 47
            self.account("isak", weekly=30, fable=22, pace=57),      # weekly 13 over: on pace; Fable ahead by 21
            self.account("even", weekly=60, fable=55),
        )
        # Widest gap first.
        self.assertEqual([(e["name"], e["gap"], e["rows"]) for e in result["behind"]],
                         [("vlahovic", 47, ["Weekly", "Fable"]), ("chief", 24, ["Weekly", "Fable"])])
        self.assertEqual([(e["name"], e["gap"], e["rows"]) for e in result["ahead"]],
                         [("trossard", 22, ["Fable"]), ("isak", 21, ["Fable"])])

    def test_summary_tooltips_name_each_row_off_pace(self):
        result = self.summary(self.account("chief", weekly=81, fable=80), self.account("gc-1", weekly=50, fable=20))
        chief = result["behind"][0]
        self.assertEqual(chief["tip"], "Weekly: 19% used, pace 43% · 24 points behind\nFable: 20% used, pace 43% · 23 points behind")
        self.assertEqual(chief["tipTurkish"], "Weekly: 19% kullanıldı, tempo 43% · 24 puan geride\nFable: 20% kullanıldı, tempo 43% · 23 puan geride")
        self.assertEqual(result["ahead"][0]["tip"], "Fable: 80% used, pace 43% · 37 points ahead")
        self.assertEqual(result["ahead"][0]["tipTurkish"], "Fable: 80% kullanıldı, tempo 43% · 37 puan önde")

    def test_an_account_behind_on_one_row_and_ahead_on_the_other_is_in_both(self):
        result = self.summary(self.account("gc-1", weekly=90, fable=20), self.account("gc-2", weekly=60))
        self.assertEqual([(e["name"], e["rows"]) for e in result["behind"]], [("gc-1", ["Weekly"])])
        self.assertEqual([(e["name"], e["rows"]) for e in result["ahead"]], [("gc-1", ["Fable"])])

    def test_equal_gaps_keep_the_list_order(self):
        result = self.summary(self.account("b", weekly=90), self.account("a", weekly=90), self.account("c", weekly=95))
        self.assertEqual([e["name"] for e in result["behind"]], ["c", "b", "a"])

    def test_rows_without_a_pace_or_a_value_are_left_out(self):
        result = self.summary(
            self.account("no-pace", weekly=95, pace=None),
            self.account("no-value", weekly=None),
            self.account("signed-out", weekly=None, fable=None),
        )
        self.assertEqual(result, {"behind": [], "ahead": []})
        self.assertEqual(self.summary(), {"behind": [], "ahead": []})


if __name__ == "__main__":
    unittest.main()
