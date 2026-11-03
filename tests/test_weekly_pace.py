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
case "room":
    let entries = (request["entries"] as! [[String: Any]]).map {
        WeeklyPace.RoomEntry(name: $0["name"] as! String, remainingPercent: int($0["remaining"]), pacePercent: int($0["pace"]))
    }
    result["value"] = WeeklyPace.roomLine(label: request["label"] as! String, entries: entries, turkish: request["turkish"] as! Bool) ?? NSNull()
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

    def room(self, entries, turkish=False):
        return self.call("room", label="Fable", entries=entries, turkish=turkish)

    def test_room_line_names_the_accounts_behind_their_pace(self):
        entries = [
            {"name": "gc-1", "remaining": 93, "pace": 34},   # 7% used: behind
            {"name": "gc-2", "remaining": 70, "pace": 34},   # 30% used: on pace
            {"name": "gc-3", "remaining": 90, "pace": 40},   # 10% used: behind
            {"name": "gc-4", "remaining": 20, "pace": 40},   # ahead
            {"name": "gc-5", "remaining": 100, "pace": None},
        ]
        self.assertEqual(self.room(entries), "Fable room: gc-1 (7% vs pace 34%), gc-3 (10% vs pace 40%)")
        self.assertEqual(self.room(entries, turkish=True), "Fable için yer var: gc-1 (7% / tempo 34%), gc-3 (10% / tempo 40%)")

    def test_no_room_line_when_no_account_is_behind(self):
        self.assertIsNone(self.room([{"name": "gc-1", "remaining": 70, "pace": 34}]))
        self.assertIsNone(self.room([]))


if __name__ == "__main__":
    unittest.main()
