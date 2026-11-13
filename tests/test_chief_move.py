import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "Sources" / "ChiefMove.swift", ROOT / "Sources" / "GrandeClaudex.swift", ROOT / "Sources" / "WeeklyPace.swift"]

HARNESS = """
import Foundation

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func describe(_ option: ChiefMove.Option) -> [String: Any] {
    let skip: Any
    switch option.skip {
    case .fiveHourFull?: skip = "fiveHourFull"
    case .aheadOfPace?: skip = "aheadOfPace"
    case .noLimits?: skip = "noLimits"
    case nil: skip = NSNull()
    }
    return [
        "alias": option.account?.alias ?? NSNull(),
        "email": option.email,
        "worker": option.worker.alias,
        "fiveHour": option.fiveHourUsed ?? NSNull(),
        "gap": option.paceGap ?? NSNull(),
        "sameDomain": option.sameDomain,
        "skip": skip,
        "line": ChiefMove.line(option, turkish: false),
        "lineTurkish": ChiefMove.line(option, turkish: true),
        "skipText": ChiefMove.skipText(option, turkish: false)
    ]
}

let request = try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: CommandLine.arguments[1])!) as! [String: Any]
let usage = try! JSONSerialization.data(withJSONObject: request["usage"]!)
let snapshot = GrandeClaudexCLI.parse(usage)!
let accounts = (request["accounts"] as! [[String: Any]]).map {
    ChiefMove.SavedAccount(alias: $0["alias"] as! String, accountUUID: $0["uuid"] as! String, email: $0["email"] as? String)
}
let plan = ChiefMove.plan(
    accounts: accounts,
    currentAccountUUID: request["currentUUID"] as? String,
    currentEmail: request["currentEmail"] as? String,
    snapshot: snapshot,
    now: Date(timeIntervalSince1970: (request["now"] as! NSNumber).doubleValue)
)
let pick: Any = plan.pick?.account?.alias ?? NSNull()
let runnerUp: Any = plan.runnerUp?.account?.alias ?? NSNull()
var result: [String: Any] = [:]
result["candidates"] = plan.candidates.map(describe)
result["skipped"] = plan.skipped.map(describe)
result["missing"] = plan.missing.map(describe)
result["pick"] = pick
result["runnerUp"] = runnerUp
emit(result)
"""

NOW = 1_792_100_000
DAY = 86_400
HOUR = 3_600


def worker(email, alias=None, five_hour=0.1, seven_day=0.2, pace=0.5, model=None, model_pace=None, **overrides):
    """A gdc `usage --json` record; `pace` is gdc's `seven_day_pace` (the share of the week passed)."""
    alias = alias or email.split("@")[0]
    row = {
        "id": "w-" + alias,
        "alias": alias,
        "kind": "claude",
        "email": email,
        "logged_in": True,
        "login_email": email,
        "plan": "team",
        "status": "allowed",
        "five_hour": five_hour,
        "five_hour_resets_at": NOW + 2 * HOUR,
        "seven_day": seven_day,
        "seven_day_resets_at": NOW + 3 * DAY,
        "seven_day_label": "all models",
        "seven_day_pace": pace,
        "seven_day_model": model,
        "seven_day_model_resets_at": NOW + 3 * DAY if model is not None else None,
        "seven_day_model_label": "Fable" if model is not None else None,
        "seven_day_model_pace": model_pace,
        "checked_at": "2026-11-13T17:23:45+00:00",
        "error": None,
    }
    row.update(overrides)
    return row


def account(alias, email, uuid=None):
    return {"alias": alias, "uuid": uuid or "uuid-" + alias, "email": email}


CURRENT = account("grandecorpo", "samet@grandecorpo.com")


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class ChiefMoveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="chief-move-test."))
        sources = cls.work / "harness"
        sources.mkdir()
        (sources / "main.swift").write_text(HARNESS)
        cls.binary = cls.work / "harness-bin"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(sources / "main.swift"), "-o", str(cls.binary)],
            check=True,
            capture_output=True,
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, ignore_errors=True)

    def plan(self, accounts, workers, current=CURRENT, current_email=None):
        request = {
            "accounts": [current, *accounts] if current else accounts,
            "currentUUID": current["uuid"] if current else None,
            "currentEmail": current_email or (current["email"] if current else None),
            "usage": {"chief": "samet@grandecorpo.com", "generated_at": "2026-11-13T17:25:18+00:00", "workers": workers},
            "now": NOW,
        }
        path = self.work / "request.json"
        path.write_text(json.dumps(request))
        result = subprocess.run([str(self.binary), str(path)], check=True, capture_output=True, text=True)
        return json.loads(result.stdout)

    def aliases(self, options):
        return [option["alias"] for option in options]

    def test_full_five_hour_window_is_skipped(self):
        plan = self.plan(
            [account("grande1", "grande1@grandecorpo.com"), account("grande2", "grande2@grandecorpo.com")],
            [worker("grande1@grandecorpo.com", five_hour=0.8, seven_day=0.05, pace=0.6),
             worker("grande2@grandecorpo.com", five_hour=0.79, seven_day=0.4, pace=0.6)],
        )
        self.assertEqual(self.aliases(plan["candidates"]), ["grande2"])
        self.assertEqual(self.aliases(plan["skipped"]), ["grande1"])
        self.assertEqual(plan["skipped"][0]["skip"], "fiveHourFull")
        self.assertEqual(plan["skipped"][0]["skipText"], "5h 80%")

    def test_weekly_use_ahead_of_pace_is_skipped(self):
        plan = self.plan(
            [account("grande1", "grande1@grandecorpo.com"), account("grande2", "grande2@grandecorpo.com"),
             account("grande3", "grande3@grandecorpo.com")],
            [worker("grande1@grandecorpo.com", seven_day=0.51, pace=0.5),
             # The general week is on pace, the Fable week ran ahead of it.
             worker("grande2@grandecorpo.com", seven_day=0.2, pace=0.5, model=0.62, model_pace=0.5),
             worker("grande3@grandecorpo.com", seven_day=0.5, pace=0.5)],
        )
        self.assertEqual(self.aliases(plan["candidates"]), ["grande3"])
        self.assertEqual([(o["alias"], o["skip"]) for o in plan["skipped"]],
                         [("grande1", "aheadOfPace"), ("grande2", "aheadOfPace")])
        self.assertEqual(plan["skipped"][1]["skipText"], "Fable 12 points ahead of the pace")

    def test_lowest_pace_gap_wins_then_lowest_five_hour(self):
        plan = self.plan(
            [account("a", "a@grandecorpo.com"), account("b", "b@grandecorpo.com"),
             account("c", "c@grandecorpo.com"), account("d", "d@grandecorpo.com")],
            [worker("a@grandecorpo.com", five_hour=0.0, seven_day=0.4, pace=0.5),   # 10 behind
             worker("b@grandecorpo.com", five_hour=0.5, seven_day=0.1, pace=0.6),   # 50 behind
             worker("c@grandecorpo.com", five_hour=0.3, seven_day=0.2, pace=0.7),   # 50 behind, less 5h
             # The general week is 60 behind but the Fable week only 5: the tighter row counts.
             worker("d@grandecorpo.com", five_hour=0.0, seven_day=0.1, pace=0.7, model=0.65, model_pace=0.7)],
        )
        self.assertEqual(self.aliases(plan["candidates"]), ["c", "b", "a", "d"])
        self.assertEqual([o["gap"] for o in plan["candidates"]], [-50, -50, -10, -5])
        self.assertEqual(plan["pick"], "c")
        self.assertEqual(plan["runnerUp"], "b")
        self.assertEqual(plan["candidates"][0]["line"],
                         "c@grandecorpo.com (c): 5h 30% · weekly 20% (pace 70%) · 50 points behind the pace")
        self.assertEqual(plan["candidates"][3]["lineTurkish"],
                         "d@grandecorpo.com (d): 5 saat 0% · haftalık 10% (tempo 70%) · Fable 65% (tempo 70%) · tempodan 5 puan geride")

    def test_same_domain_is_preferred(self):
        plan = self.plan(
            [account("kartal", "grande1@kartalrecord.com"), account("grande3", "grande3@grandecorpo.com")],
            [worker("grande1@kartalrecord.com", five_hour=0.0, seven_day=0.02, pace=0.8),
             worker("grande3@grandecorpo.com", five_hour=0.4, seven_day=0.45, pace=0.5)],
        )
        self.assertEqual(self.aliases(plan["candidates"]), ["grande3", "kartal"])
        self.assertEqual([o["sameDomain"] for o in plan["candidates"]], [True, False])

    def test_current_account_is_excluded(self):
        plan = self.plan(
            [account("grande1", "grande1@grandecorpo.com")],
            [worker("samet@grandecorpo.com", five_hour=0.0, seven_day=0.0, pace=0.9),
             worker("grande1@grandecorpo.com", seven_day=0.3, pace=0.5)],
        )
        self.assertEqual(self.aliases(plan["candidates"]), ["grande1"])
        self.assertEqual(plan["skipped"], [])
        self.assertEqual(plan["missing"], [])

    def test_no_candidates_names_the_worker_accounts_to_add(self):
        plan = self.plan(
            [account("grande2", "grande2@grandecorpo.com"), account("personal", "me@example.com")],
            [worker("grande2@grandecorpo.com", five_hour=1.0, five_hour_resets_at=None, seven_day=0.09, pace=0.6),
             worker("grande3@grandecorpo.com", alias="salih", seven_day=0.1, pace=0.46),
             worker("samet@kartalrecord.com", alias="olaitan", seven_day=0.04, pace=0.23),
             # Without room it is not worth adding.
             worker("grande9@grandecorpo.com", alias="full", five_hour=0.95)],
        )
        self.assertEqual(plan["candidates"], [])
        self.assertIsNone(plan["pick"])
        self.assertIsNone(plan["runnerUp"])
        self.assertEqual(self.aliases(plan["skipped"]), ["grande2"])
        self.assertEqual([o["email"] for o in plan["missing"]], ["grande3@grandecorpo.com", "samet@kartalrecord.com"])
        self.assertEqual([o["alias"] for o in plan["missing"]], [None, None])

    def test_saved_accounts_that_are_not_workers_are_left_out(self):
        plan = self.plan(
            [account("personal", "me@example.com"), account("nomail", None)],
            [worker("grande1@grandecorpo.com")],
        )
        self.assertEqual(plan["candidates"], [])
        self.assertEqual(plan["skipped"], [])
        self.assertEqual([o["email"] for o in plan["missing"]], ["grande1@grandecorpo.com"])

    def test_email_match_ignores_case(self):
        plan = self.plan([account("g1", "Grande1@GrandeCorpo.com")], [worker("grande1@grandecorpo.com")])
        self.assertEqual(self.aliases(plan["candidates"]), ["g1"])
        self.assertTrue(plan["candidates"][0]["sameDomain"])

    def test_signed_out_worker_has_no_limits(self):
        plan = self.plan(
            [account("g1", "grande1@grandecorpo.com")],
            [worker("grande1@grandecorpo.com", logged_in=False)],
        )
        self.assertEqual(plan["candidates"], [])
        self.assertEqual(plan["skipped"][0]["skip"], "noLimits")

    def test_windows_whose_reset_passed_count_as_unused(self):
        plan = self.plan(
            [account("g1", "grande1@grandecorpo.com")],
            [worker("grande1@grandecorpo.com", five_hour=0.97, five_hour_resets_at=NOW - 60,
                    seven_day=0.99, seven_day_resets_at=NOW - 60, pace=None)],
        )
        self.assertEqual(self.aliases(plan["candidates"]), ["g1"])
        self.assertEqual(plan["candidates"][0]["fiveHour"], 0)
        self.assertIsNone(plan["candidates"][0]["gap"])

    def test_pace_comes_from_the_reset_time_without_gdc_pace(self):
        # Reset in 3 days: 4 of 7 days passed, a 57% pace.
        plan = self.plan(
            [account("g1", "grande1@grandecorpo.com")],
            [worker("grande1@grandecorpo.com", seven_day=0.6, pace=None)],
        )
        self.assertEqual(plan["skipped"][0]["skip"], "aheadOfPace")
        self.assertEqual(plan["skipped"][0]["gap"], 3)

    def test_without_a_current_account_nothing_is_excluded_or_preferred(self):
        plan = self.plan(
            [account("kartal", "grande1@kartalrecord.com"), account("g3", "grande3@grandecorpo.com")],
            [worker("grande1@kartalrecord.com", seven_day=0.02, pace=0.8),
             worker("grande3@grandecorpo.com", seven_day=0.45, pace=0.5)],
            current=None,
        )
        self.assertEqual(self.aliases(plan["candidates"]), ["kartal", "g3"])
        self.assertEqual([o["sameDomain"] for o in plan["candidates"]], [False, False])


if __name__ == "__main__":
    unittest.main()
