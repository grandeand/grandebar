import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "Sources" / "ClaudeLimitResets.swift"]

HARNESS = """
import Foundation

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func describe(_ resets: ClaudeLimitResets?) -> Any {
    guard let resets else { return NSNull() }
    return ["count": resets.count, "expiries": resets.expiries.map(\\.timeIntervalSince1970)] as [String: Any]
}

func format(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }

let arguments = CommandLine.arguments
let input = try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: arguments[2])!) as! [String: Any]
let now = Date(timeIntervalSince1970: input["now"] as! Double)
switch arguments[1] {
case "parse":
    emit(["resets": describe(ClaudeLimitResets.parse(input["usage"] as! [String: Any], now: now))])
case "stored":
    let expiries = (input["expiries"] as? [Double])?.map { Date(timeIntervalSince1970: $0) }
    emit(["resets": describe(ClaudeLimitResets.stored(count: input["count"] as? Int, expiries: expiries, now: now))])
case "text":
    let count = input["count"] as? Int
    let expiries = (input["expiries"] as? [Double] ?? []).map { Date(timeIntervalSince1970: $0) }
    let counts = (input["counts"] as? [Any] ?? []).map { $0 as? Int }
    emit([
        "lineEN": ClaudeLimitResets.cardLine(count: count, expiries: expiries, now: now, turkish: false, format: format).map { $0 as Any } ?? NSNull(),
        "lineTR": ClaudeLimitResets.cardLine(count: count, expiries: expiries, now: now, turkish: true, format: format).map { $0 as Any } ?? NSNull(),
        "tipEN": ClaudeLimitResets.chipToolTip(count: count, turkish: false).map { $0 as Any } ?? NSNull(),
        "tipTR": ClaudeLimitResets.chipToolTip(count: count, turkish: true).map { $0 as Any } ?? NSNull(),
        "header": ClaudeLimitResets.headerSuffix(counts)
    ])
default:
    exit(2)
}
"""

NOW = 1_794_600_000
DAY = 86_400


def iso(epoch):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def grant(resets_left=1, ends_at=NOW + 7 * DAY, **overrides):
    """One grant of the `cedar_ember` block, with the fields Claude Code 2.1.323's schema reads."""
    row = {
        "id": "grant_1", "label": "Limit reset", "resets_total": resets_left, "resets_left": resets_left,
        "starts_at": iso(NOW - DAY), "ends_at": iso(ends_at) if isinstance(ends_at, int) else ends_at,
        "clears": ["five_hour"], "paused": False, "usable_now": False, "use_requires_limit": True,
        "percent_used": {"five_hour": 12}, "blocking": [], "type": "session", "gives_back_weekly": False,
        "unavailable_reason": None,
    }
    row.update(overrides)
    return row


def usage(cedar_ember="absent"):
    """A `/api/oauth/usage?cedar_ember=1&skip_spend=1` answer: the usual limits plus the block."""
    body = {
        "five_hour": {"utilization": 12, "resets_at": iso(NOW + 3600)},
        "seven_day": {"utilization": 40, "resets_at": iso(NOW + 4 * DAY)},
        "limits": [{"kind": "session", "group": "session", "percent": 12, "resets_at": iso(NOW + 3600)}],
    }
    if cedar_ember != "absent":
        body["cedar_ember"] = cedar_ember
    return body


def block(*grants, eligible=True, **overrides):
    row = {"eligible": eligible, "ineligible_reason": None if eligible else "tier", "at_limit": False, "exhausted": [],
           "grants": list(grants), "next_grant_id": grants[0]["id"] if grants else None,
           "weekly_resets_at": iso(NOW + 4 * DAY), "cooldown_until": None}
    row.update(overrides)
    return row


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class ClaudeLimitResetsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="claude-limit-resets-test."))
        (cls.work / "main.swift").write_text(HARNESS)
        cls.binary = cls.work / "harness-bin"
        subprocess.run(["swiftc", *map(str, SOURCES), str(cls.work / "main.swift"), "-o", str(cls.binary)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, ignore_errors=True)

    def run_harness(self, command, **values):
        path = self.work / "input.json"
        path.write_text(json.dumps({"now": NOW, **values}))
        result = subprocess.run([str(self.binary), command, str(path)], check=True, capture_output=True, text=True)
        return json.loads(result.stdout)

    def parse(self, body):
        return self.run_harness("parse", usage=body)["resets"]

    def test_grants_add_up_with_one_expiry_per_reset(self):
        resets = self.parse(usage(block(
            grant(id="weekly", resets_left=2, ends_at=NOW + 9 * DAY, type="weekly"),
            grant(id="session", resets_left=1, ends_at=NOW + 2 * DAY),
        )))
        self.assertEqual(resets, {"count": 3, "expiries": [NOW + 2 * DAY, NOW + 9 * DAY, NOW + 9 * DAY]})

    def test_a_null_block_holds_no_reset(self):
        # What a plain usage read carries, and what Claude Code reads as "no reset to use".
        self.assertEqual(self.parse(usage(None)), {"count": 0, "expiries": []})

    def test_no_block_at_all_is_unknown(self):
        self.assertIsNone(self.parse(usage()))

    def test_a_block_that_is_not_an_object_is_unknown(self):
        self.assertIsNone(self.parse(usage("eligible")))
        self.assertIsNone(self.parse(usage([block(grant())])))

    def test_an_ineligible_account_holds_no_reset(self):
        self.assertEqual(self.parse(usage(block(grant(resets_left=2), eligible=False))), {"count": 0, "expiries": []})
        self.assertEqual(self.parse(usage({"grants": [grant()]})), {"count": 0, "expiries": []})

    def test_eligible_without_grants_holds_no_reset(self):
        self.assertEqual(self.parse(usage(block())), {"count": 0, "expiries": []})

    def test_used_up_and_run_out_grants_are_left_out(self):
        resets = self.parse(usage(block(
            grant(id="used", resets_left=0),
            grant(id="ran-out", resets_left=2, ends_at=NOW - 60),
            grant(id="kept", resets_left=1, ends_at=NOW + DAY),
        )))
        self.assertEqual(resets, {"count": 1, "expiries": [NOW + DAY]})

    def test_a_grant_without_an_end_is_counted_not_listed(self):
        resets = self.parse(usage(block(grant(resets_left=2, ends_at=None))))
        self.assertEqual(resets, {"count": 2, "expiries": []})

    def test_a_paused_grant_still_counts(self):
        # Claude Code's "{resets} left" adds every grant, paused ones too.
        resets = self.parse(usage(block(grant(resets_left=1, paused=True))))
        self.assertEqual(resets["count"], 1)

    def test_unreadable_grants_are_dropped(self):
        resets = self.parse(usage(block(
            grant(id="text", resets_left="2"),
            grant(id="bool", resets_left=True),
            grant(id="negative", resets_left=-1),
            grant(id="fraction", resets_left=1.5),
            grant(id="good", resets_left=1, ends_at=NOW + DAY),
            "not a grant",
        )))
        self.assertEqual(resets, {"count": 1, "expiries": [NOW + DAY]})

    def test_end_dates_without_fractions_are_read(self):
        resets = self.parse(usage(block(grant(resets_left=1, ends_at="2026-11-20T12:00:00Z"))))
        self.assertEqual(resets, {"count": 1, "expiries": [1_795_176_000]})

    def test_a_stored_read_loses_the_resets_that_ran_out(self):
        stored = self.run_harness("stored", count=3, expiries=[NOW + DAY, NOW - 60, NOW + 2 * DAY])["resets"]
        self.assertEqual(stored, {"count": 2, "expiries": [NOW + DAY, NOW + 2 * DAY]})
        self.assertIsNone(self.run_harness("stored", count=None, expiries=[NOW + DAY])["resets"])
        self.assertEqual(self.run_harness("stored", count=0, expiries=None)["resets"], {"count": 0, "expiries": []})

    def test_card_and_header_texts(self):
        text = self.run_harness("text", count=2, expiries=[NOW + 9 * DAY, NOW + 2 * DAY], counts=[2, None, 0, 1])
        self.assertEqual(text["lineEN"], f"Reset 2 · first credit expires {NOW + 2 * DAY}")
        self.assertEqual(text["lineTR"], f"Reset 2 · ilk hak bitişi {NOW + 2 * DAY}")
        self.assertEqual(text["tipEN"], "2 limit reset(s) left (Claude Code's /limit-reset)")
        self.assertEqual(text["tipTR"], "2 limit reset hakkı kaldı (Claude Code /limit-reset)")
        self.assertEqual(text["header"], " · 3 reset")

    def test_unknown_count_changes_nothing(self):
        text = self.run_harness("text", count=None, expiries=[NOW + DAY], counts=[None, None])
        self.assertIsNone(text["lineEN"])
        self.assertIsNone(text["tipEN"])
        self.assertEqual(text["header"], "")

    def test_zero_shows_in_the_header_and_tooltip_not_on_the_card(self):
        text = self.run_harness("text", count=0, expiries=[], counts=[0, None])
        self.assertIsNone(text["lineEN"])
        self.assertEqual(text["tipEN"], "No limit resets (Claude Code's /limit-reset)")
        self.assertEqual(text["header"], " · 0 reset")

    def test_resets_without_an_end_show_the_count_alone(self):
        text = self.run_harness("text", count=2, expiries=[], counts=[2])
        self.assertEqual(text["lineEN"], "Reset 2")

    def test_an_expiry_that_passed_is_not_the_first(self):
        text = self.run_harness("text", count=1, expiries=[NOW - 60, NOW + DAY], counts=[1])
        self.assertEqual(text["lineEN"], f"Reset 1 · first credit expires {NOW + DAY}")

if __name__ == "__main__":
    unittest.main()
