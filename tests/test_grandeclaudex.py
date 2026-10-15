import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources" / "GrandeClaudex.swift"

HARNESS = """
import Foundation

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func window(_ value: GrandeClaudexWindow?) -> Any {
    guard let value else { return NSNull() }
    return ["remaining": value.remainingPercent, "reset": value.resetSeconds ?? NSNull(), "hasReset": value.hasReset] as [String: Any]
}

func describe(_ snapshot: GrandeClaudexSnapshot, now: Date) -> [String: Any] {
    [
        "chief": snapshot.chief ?? NSNull(),
        "generatedAt": snapshot.generatedAt?.timeIntervalSince1970 ?? NSNull(),
        "workers": snapshot.workers.map { worker in
            [
                "id": worker.id,
                "alias": worker.alias,
                "email": worker.email ?? NSNull(),
                "loggedIn": worker.loggedIn,
                "status": worker.status ?? NSNull(),
                "fiveHour": window(worker.fiveHourWindow(now: now)),
                "sevenDay": window(worker.sevenDayWindow(now: now)),
                "checkedAt": worker.checkedAt?.timeIntervalSince1970 ?? NSNull(),
                "error": worker.error ?? NSNull()
            ] as [String: Any]
        }
    ]
}

let arguments = CommandLine.arguments
switch arguments[1] {
case "parse":
    let data = FileManager.default.contents(atPath: arguments[2])!
    let now = Date(timeIntervalSince1970: Double(arguments[3])!)
    if let snapshot = GrandeClaudexCLI.parse(data) {
        emit(describe(snapshot, now: now))
    } else {
        emit(["unreadable": true])
    }
case "fetch":
    switch GrandeClaudexCLI.fetch(probe: arguments[3] == "probe", executable: arguments[2], timeout: Double(arguments[4])!) {
    case .success(let snapshot): emit(["ok": describe(snapshot, now: Date())])
    case .failure(.notInstalled): emit(["failure": "notInstalled"])
    case .failure(.unreadable): emit(["failure": "unreadable"])
    case .failure(.failed(let message)): emit(["failure": "failed", "message": message])
    }
default:
    exit(2)
}
"""

NOW = 1_792_100_000


def worker(**overrides):
    row = {
        "id": "gc-grande1",
        "alias": "gc-grande1",
        "kind": "claude",
        "email": "grande1@example.com",
        "logged_in": True,
        "login_email": "grande1@example.com",
        "model": None,
        "status": "allowed",
        "five_hour": 0.04,
        "five_hour_resets_at": NOW + 6400,
        "seven_day": None,
        "seven_day_resets_at": None,
        "checked_at": "2026-10-15T21:04:55.647396+00:00",
        "error": None,
    }
    row.update(overrides)
    return row


def payload(*workers):
    return {"chief": "chief@example.com", "generated_at": "2026-10-15T21:20:41.200794+00:00", "workers": list(workers)}


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class GrandeClaudexTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="grandeclaudex-test."))
        sources = cls.work / "harness"
        sources.mkdir()
        (sources / "main.swift").write_text(HARNESS)
        cls.binary = cls.work / "harness-bin"
        subprocess.run(
            ["swiftc", str(SOURCE), str(sources / "main.swift"), "-o", str(cls.binary)],
            check=True,
            capture_output=True,
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, ignore_errors=True)

    def parse(self, data, raw=None):
        path = self.work / "input.json"
        path.write_text(raw if raw is not None else json.dumps(data))
        result = subprocess.run([str(self.binary), "parse", str(path), str(NOW)], check=True, capture_output=True, text=True)
        return json.loads(result.stdout)

    def fake_gdc(self, body):
        script = self.work / "gdc"
        script.write_text("#!/bin/sh\n" + body)
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        return script

    def fetch(self, executable, probe=False, timeout=20):
        result = subprocess.run(
            [str(self.binary), "fetch", str(executable), "probe" if probe else "cache", str(timeout)],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def test_only_claude_workers_are_kept_in_order(self):
        parsed = self.parse(payload(
            worker(id="gc-grande1"),
            worker(id="cx-1", alias="cx-1", kind="codex"),
            worker(id="kr-samet", alias="kr-samet"),
        ))
        self.assertEqual([w["id"] for w in parsed["workers"]], ["gc-grande1", "kr-samet"])
        self.assertEqual(parsed["chief"], "chief@example.com")

    def test_utilization_becomes_remaining_with_reset_countdown(self):
        parsed = self.parse(payload(worker(five_hour=0.04, seven_day=0.5, seven_day_resets_at=NOW + 90_000)))
        row = parsed["workers"][0]
        self.assertEqual(row["fiveHour"], {"remaining": 96, "reset": 6400, "hasReset": False})
        self.assertEqual(row["sevenDay"], {"remaining": 50, "reset": 90_000, "hasReset": False})

    def test_unknown_values_stay_unknown(self):
        row = self.parse(payload(worker(five_hour=None, five_hour_resets_at=None)))["workers"][0]
        self.assertIsNone(row["fiveHour"])
        self.assertIsNone(row["sevenDay"])

    def test_elapsed_reset_shows_a_full_window(self):
        row = self.parse(payload(worker(five_hour=0.9, five_hour_resets_at=NOW - 60)))["workers"][0]
        self.assertEqual(row["fiveHour"], {"remaining": 100, "reset": None, "hasReset": True})

    def test_logged_out_worker_and_error_are_reported(self):
        parsed = self.parse(payload(
            worker(id="a", logged_in=False, login_email=None, status=None, five_hour=None, five_hour_resets_at=None, checked_at=None),
            worker(id="b", error="probe failed"),
        ))
        logged_out, failing = parsed["workers"]
        self.assertFalse(logged_out["loggedIn"])
        self.assertIsNone(logged_out["checkedAt"])
        self.assertEqual(failing["error"], "probe failed")

    def test_dates_with_and_without_fractions_are_parsed(self):
        parsed = self.parse(payload(
            worker(checked_at="2026-10-15T21:04:55.647396+00:00"),
            worker(id="b", checked_at="2026-10-15T21:04:55+00:00"),
        ))
        first, second = (w["checkedAt"] for w in parsed["workers"])
        self.assertAlmostEqual(first, 1_792_098_295.647, places=2)
        self.assertEqual(second, 1_792_098_295)

    def test_garbage_is_unreadable(self):
        self.assertEqual(self.parse(None, raw="not json"), {"unreadable": True})
        self.assertEqual(self.parse({"chief": "x"}), {"unreadable": True})

    def test_fetch_reads_the_cache_and_probes_only_when_asked(self):
        calls = self.work / "calls.txt"
        calls.unlink(missing_ok=True)
        body = json.dumps(payload(worker()))
        gdc = self.fake_gdc(f"echo \"$@\" >> '{calls}'\ncat <<'EOF'\n{body}\nEOF\n")
        self.assertEqual(self.fetch(gdc)["ok"]["workers"][0]["id"], "gc-grande1")
        self.fetch(gdc, probe=True)
        self.assertEqual(calls.read_text().splitlines(), ["usage --json", "usage --json --probe"])

    def test_fetch_failures(self):
        self.assertEqual(self.fetch(self.work / "missing-gdc"), {"failure": "notInstalled"})
        failing = self.fake_gdc("echo 'no cache' >&2\nexit 3\n")
        self.assertEqual(self.fetch(failing), {"failure": "failed", "message": "no cache"})
        garbage = self.fake_gdc("echo not-json\n")
        self.assertEqual(self.fetch(garbage), {"failure": "unreadable"})

    def test_fetch_stops_a_hung_gdc(self):
        hung = self.fake_gdc("sleep 30\n")
        result = self.fetch(hung, timeout=1)
        self.assertEqual(result["failure"], "failed")


if __name__ == "__main__":
    unittest.main()
