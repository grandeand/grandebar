import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "Sources" / "QuotaFile.swift"]

HARNESS = """
import Foundation

let input = try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: CommandLine.arguments[1])!) as! [String: Any]
let target = URL(fileURLWithPath: CommandLine.arguments[2])

func window(_ key: String) -> QuotaFileWindow? {
    guard let row = input[key] as? [String: Any] else { return nil }
    return QuotaFileWindow(remaining: row["remaining"] as? Int, resetsAt: (row["resets"] as? Double).map { Date(timeIntervalSince1970: $0) })
}

var snapshot = QuotaFileSnapshot(
    mode: input["mode"] as! String,
    scope: input["scope"] as! String,
    plan: input["plan"] as? String,
    account: input["account"] as? String,
    accountCount: input["account_count"] as? Int,
    updatedAt: Date(timeIntervalSince1970: input["updated"] as! Double),
    version: "0.2.37"
)
snapshot.fiveHour = window("five_hour")
snapshot.sevenDay = window("seven_day")
for (label, _) in input["models"] as? [String: Any] ?? [:] {
    snapshot.modelWeekly[label] = window("model_" + label)
}
snapshot.sessionPoolPercent = input["session_pool"] as? Int
print(QuotaFile.write(snapshot, to: target) ? "ok" : "failed")
"""

UPDATED = 1_794_600_000  # 2026-11-13T20:00:00Z
SESSION_RESET = UPDATED + 3_600
WEEKLY_RESET = UPDATED + 3 * 86_400


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class QuotaFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="quota-file-test."))
        (cls.work / "main.swift").write_text(HARNESS)
        cls.binary = cls.work / "harness-bin"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.work / "main.swift"), "-o", str(cls.binary)],
            check=True, capture_output=True,
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, ignore_errors=True)

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix="case.", dir=self.work))

    def write(self, snapshot, target):
        path = self.case / "input.json"
        path.write_text(json.dumps(snapshot))
        result = subprocess.run([str(self.binary), str(path), str(target)], check=True, capture_output=True, text=True)
        return result.stdout.strip()

    def claude_account(self, **extra):
        snapshot = {
            "mode": "claude", "scope": "account", "plan": "Max 5x", "account": "Desktop · work",
            "updated": UPDATED,
            "five_hour": {"remaining": 60, "resets": SESSION_RESET},
            "seven_day": {"remaining": 86, "resets": WEEKLY_RESET},
            "models": {"Fable": True},
            "model_Fable": {"remaining": 89, "resets": WEEKLY_RESET},
        }
        snapshot.update(extra)
        return snapshot

    def test_claude_account_file(self):
        target = self.case / "config" / "grandebar" / "quota.json"
        self.assertEqual(self.write(self.claude_account(), target), "ok")
        data = json.loads(target.read_text())
        self.assertEqual(data["mode"], "claude")
        self.assertEqual(data["scope"], "account")
        self.assertEqual(data["plan"], "Max 5x")
        self.assertEqual(data["account"], "Desktop · work")
        self.assertEqual(data["five_hour"], {"utilization": 40, "resets_at": "2026-11-13T21:00:00Z"})
        self.assertEqual(data["seven_day"], {"utilization": 14, "resets_at": "2026-11-16T20:00:00Z"})
        self.assertEqual(data["seven_day_fable"], {"utilization": 11, "resets_at": "2026-11-16T20:00:00Z"})
        self.assertEqual(data["updated_at"], "2026-11-13T20:00:00Z")
        self.assertEqual(data["source"], "grandebar 0.2.37")
        self.assertNotIn("session_pool_percent", data)
        self.assertNotIn("seven_day_opus", data)
        # Only the file itself is left in the folder: the temporary file was renamed over it.
        self.assertEqual([p.name for p in target.parent.iterdir()], ["quota.json"])

    def test_codex_pool_file(self):
        target = self.case / "quota.json"
        snapshot = {
            "mode": "codex", "scope": "pool", "plan": "Team", "account": "CLIProxy pool", "account_count": 3,
            "updated": UPDATED, "session_pool": 72,
            "five_hour": {"remaining": 72, "resets": SESSION_RESET},
            "seven_day": {"remaining": 55},
        }
        self.assertEqual(self.write(snapshot, target), "ok")
        data = json.loads(target.read_text())
        self.assertEqual(data["mode"], "codex")
        self.assertEqual(data["session_pool_percent"], 72)
        self.assertEqual(data["account_count"], 3)
        self.assertEqual(data["five_hour"]["utilization"], 28)
        self.assertEqual(data["seven_day"], {"utilization": 45, "resets_at": None})

    def test_no_email_reaches_the_file(self):
        target = self.case / "quota.json"
        self.write(self.claude_account(account="someone@example.com", plan="x@y"), target)
        text = target.read_text()
        self.assertNotIn("@", text)
        data = json.loads(text)
        self.assertIsNone(data["account"])
        self.assertIsNone(data["plan"])

    def test_missing_windows_are_null_and_odd_model_labels_are_skipped(self):
        target = self.case / "quota.json"
        snapshot = {"mode": "claude", "scope": "account", "updated": UPDATED,
                    "models": {"../evil key": True}, "model_../evil key": {"remaining": 10}}
        self.write(snapshot, target)
        data = json.loads(target.read_text())
        self.assertIsNone(data["five_hour"])
        self.assertIsNone(data["seven_day"])
        self.assertFalse([key for key in data if key.startswith("seven_day_")])

    def test_failed_write_keeps_the_previous_file(self):
        folder = self.case / "locked"
        target = folder / "quota.json"
        self.assertEqual(self.write(self.claude_account(), target), "ok")
        before = target.read_text()
        os.chmod(folder, stat.S_IRUSR | stat.S_IXUSR)
        try:
            result = self.write(self.claude_account(five_hour={"remaining": 1}), target)
        finally:
            os.chmod(folder, stat.S_IRWXU)
        self.assertEqual(result, "failed")
        self.assertEqual(target.read_text(), before)

    def test_unwritable_location_fails_quietly(self):
        blocker = self.case / "blocker"
        blocker.write_text("not a folder")
        self.assertEqual(self.write(self.claude_account(), blocker / "quota.json"), "failed")


if __name__ == "__main__":
    unittest.main()
