import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = sorted(path for path in (ROOT / "Sources").glob("*.swift") if path.name != "main.swift")

HARNESS = """
import Foundation

let data = FileManager.default.contents(atPath: CommandLine.arguments[1])!
let usage = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
let quota = ClaudeQuota.parse(usage)
let result: [String: Any] = [
    "session": quota.sessionRemaining ?? NSNull(),
    "weekly": quota.weeklyRemaining ?? NSNull(),
    "weeklyLabel": quota.weeklyLabel ?? NSNull(),
    "weeklyResetsAt": quota.weeklyResetDate?.timeIntervalSince1970 ?? NSNull(),
    "modelWeekly": quota.modelWeeklyRemaining ?? NSNull(),
    "modelWeeklyLabel": quota.modelWeeklyLabel ?? NSNull(),
    "modelWeeklyResetsAt": quota.modelWeeklyResetDate?.timeIntervalSince1970 ?? NSNull(),
    "limitReached": quota.limitReached
]
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
"""

WEEKLY_RESET = "2026-11-08T12:00:00Z"
WEEKLY_RESET_EPOCH = 1_794_139_200
SESSION_RESET = "2026-11-03T23:20:00Z"


def limit(kind=None, group=None, percent=0, resets_at=WEEKLY_RESET, model=None):
    """One entry of the usage API's `limits` array."""
    row = {"percent": percent, "resets_at": resets_at}
    if kind:
        row["kind"] = kind
    if group:
        row["group"] = group
    if model:
        row["scope"] = {"model": {"display_name": model}}
    return row


def session(percent=40):
    return limit(kind="session", group="session", percent=percent, resets_at=SESSION_RESET)


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class ClaudeQuotaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="claude-quota-test."))
        (cls.work / "main.swift").write_text(HARNESS)
        cls.binary = cls.work / "harness-bin"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.work / "main.swift"),
             "-framework", "AppKit", "-framework", "ServiceManagement", "-o", str(cls.binary)],
            check=True, capture_output=True,
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, ignore_errors=True)

    def parse(self, usage):
        path = self.work / "usage.json"
        path.write_text(json.dumps(usage))
        result = subprocess.run([str(self.binary), str(path)], check=True, capture_output=True, text=True)
        return json.loads(result.stdout)

    def test_three_limits_fill_the_weekly_and_the_model_rows(self):
        # The claude.ai usage screen: 5h 40%, weekly (all models) 14%, weekly Fable 11% used.
        parsed = self.parse({"limits": [
            session(40),
            limit(group="weekly", percent=14),
            limit(group="weekly", percent=11, model="Fable"),
        ]})
        self.assertEqual(parsed["session"], 60)
        self.assertEqual(parsed["weekly"], 86)
        self.assertIsNone(parsed["weeklyLabel"])
        self.assertEqual(parsed["weeklyResetsAt"], WEEKLY_RESET_EPOCH)
        self.assertEqual(parsed["modelWeekly"], 89)
        self.assertEqual(parsed["modelWeeklyLabel"], "Fable")
        self.assertEqual(parsed["modelWeeklyResetsAt"], WEEKLY_RESET_EPOCH)
        self.assertFalse(parsed["limitReached"])

    def test_general_weekly_alone_has_no_model_row(self):
        parsed = self.parse({"limits": [session(), limit(group="weekly", percent=14)]})
        self.assertEqual(parsed["weekly"], 86)
        self.assertIsNone(parsed["weeklyLabel"])
        self.assertIsNone(parsed["modelWeekly"])
        self.assertIsNone(parsed["modelWeeklyLabel"])

    def test_model_weekly_alone_is_the_weekly_row(self):
        parsed = self.parse({"limits": [session(), limit(group="weekly", percent=11, model="Fable")]})
        self.assertEqual(parsed["weekly"], 89)
        self.assertEqual(parsed["weeklyLabel"], "Fable")
        self.assertIsNone(parsed["modelWeekly"])
        self.assertIsNone(parsed["modelWeeklyLabel"])

    def test_fable_is_preferred_among_several_model_weeklies(self):
        parsed = self.parse({"limits": [
            session(),
            limit(group="weekly", percent=14),
            limit(group="weekly", percent=50, model="Opus"),
            limit(group="weekly", percent=11, model="Fable"),
        ]})
        self.assertEqual(parsed["modelWeeklyLabel"], "Fable")
        self.assertEqual(parsed["modelWeekly"], 89)

    def test_legacy_windows_carry_both_weeklies(self):
        parsed = self.parse({
            "five_hour": {"utilization": 40, "resets_at": SESSION_RESET},
            "seven_day": {"utilization": 14, "resets_at": WEEKLY_RESET},
            "seven_day_fable": {"utilization": 11, "resets_at": WEEKLY_RESET},
        })
        self.assertEqual(parsed["session"], 60)
        self.assertEqual(parsed["weekly"], 86)
        self.assertEqual(parsed["modelWeekly"], 89)
        self.assertEqual(parsed["modelWeeklyLabel"], "Fable")

    def test_only_the_general_weekly_running_out_locks_the_account(self):
        general = self.parse({"limits": [session(), limit(group="weekly", percent=100), limit(group="weekly", percent=11, model="Fable")]})
        self.assertTrue(general["limitReached"])
        model = self.parse({"limits": [session(), limit(group="weekly", percent=14), limit(group="weekly", percent=100, model="Fable")]})
        self.assertFalse(model["limitReached"])
        self.assertEqual(model["modelWeekly"], 0)


if __name__ == "__main__":
    unittest.main()
