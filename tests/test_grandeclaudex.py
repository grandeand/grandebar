import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time
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
                "plan": worker.planTitle ?? NSNull(),
                "weeklyModel": worker.weeklyModel ?? NSNull(),
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
    case .failure(.timedOut): emit(["failure": "timedOut"])
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
        "plan": "team",
        "org": "Example",
        "model": None,
        "status": "allowed",
        "five_hour": 0.04,
        "five_hour_resets_at": NOW + 6400,
        "seven_day": None,
        "seven_day_resets_at": None,
        "seven_day_label": None,
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

    def test_zero_and_full_use_are_values_not_booleans(self):
        # JSON 0.0 and 1.0 cast to Bool in Swift; they must still read as numbers.
        rows = self.parse(payload(
            worker(id="a", five_hour=0.0, seven_day=1.0, seven_day_resets_at=NOW + 60),
            worker(id="b", five_hour=0, seven_day=1, seven_day_resets_at=NOW + 60),
            worker(id="c", five_hour=True, seven_day=False),
        ))["workers"]
        for row in rows[:2]:
            self.assertEqual(row["fiveHour"]["remaining"], 100)
            self.assertEqual(row["sevenDay"]["remaining"], 0)
        self.assertIsNone(rows[2]["fiveHour"])
        self.assertIsNone(rows[2]["sevenDay"])

    def test_plan_and_weekly_row_name(self):
        rows = self.parse(payload(
            worker(id="a", plan="team", seven_day=0.28, seven_day_resets_at=NOW + 90_000, seven_day_label="Fable"),
            worker(id="b", plan="max", seven_day=0.1, seven_day_resets_at=NOW + 90_000, seven_day_label="all models"),
            worker(id="c", plan=None, seven_day_label=None),
        ))["workers"]
        self.assertEqual([(r["plan"], r["weeklyModel"]) for r in rows], [("Team", "Fable"), ("Max", None), (None, None)])
        self.assertEqual(rows[0]["sevenDay"], {"remaining": 72, "reset": 90_000, "hasReset": False})

    def test_signed_in_account_wins_over_the_configured_one(self):
        rows = self.parse(payload(
            worker(id="a", email="meant@example.com", login_email="actual@example.com"),
            worker(id="b", email="meant@example.com", login_email=None, logged_in=False),
            worker(id="c", email=None, login_email=None, alias=""),
        ))["workers"]
        self.assertEqual([r["email"] for r in rows], ["actual@example.com", "meant@example.com", None])
        self.assertEqual(rows[2]["alias"], "c")

    def test_logged_in_must_be_a_boolean(self):
        rows = self.parse(payload(worker(id="a", logged_in=1), worker(id="b", logged_in="yes"), worker(id="c", logged_in=True)))["workers"]
        self.assertEqual([r["loggedIn"] for r in rows], [False, False, True])

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
        traceback = self.fake_gdc("printf 'Traceback (most recent call last):\\n  File x\\nGdcError: no roster\\n\\n' >&2\nexit 1\n")
        self.assertEqual(self.fetch(traceback), {"failure": "failed", "message": "GdcError: no roster"})
        silent = self.fake_gdc("exit 4\n")
        self.assertEqual(self.fetch(silent), {"failure": "failed", "message": "gdc exited with 4"})
        garbage = self.fake_gdc("echo not-json\n")
        self.assertEqual(self.fetch(garbage), {"failure": "unreadable"})

    def test_fetch_stops_a_hung_gdc(self):
        hung = self.fake_gdc("exec sleep 30\n")
        started = time.monotonic()
        self.assertEqual(self.fetch(hung, timeout=1), {"failure": "timedOut"})
        self.assertLess(time.monotonic() - started, 10)

    def test_fetch_does_not_wait_on_a_child_holding_the_pipe(self):
        stray = self.fake_gdc("(sleep 30 &)\nexit 0\n")
        started = time.monotonic()
        self.assertEqual(self.fetch(stray), {"failure": "timedOut"})
        self.assertLess(time.monotonic() - started, 10)

    def test_fetch_reads_a_reply_larger_than_a_pipe_buffer(self):
        workers = [worker(id=f"w{i}", alias=f"w{i}") for i in range(1500)]
        reply = self.work / "big.json"
        reply.write_text(json.dumps(payload(*workers)))
        self.assertGreater(reply.stat().st_size, 256 * 1024)
        big = self.fake_gdc(f"cat '{reply}'\necho \"$(head -c 200000 /dev/zero | tr '\\0' x)\" >&2\n")
        self.assertEqual(len(self.fetch(big)["ok"]["workers"]), 1500)

    def test_fetch_finds_tools_in_the_user_bin(self):
        script = 'printf \'{"chief": "%s", "workers": []}\' "$PATH"\n'
        path = self.fetch(self.fake_gdc(script))["ok"]["chief"].split(":")
        self.assertEqual(path[0], str(Path.home() / ".local/bin"))
        self.assertIn("/opt/homebrew/bin", path)


if __name__ == "__main__":
    unittest.main()
