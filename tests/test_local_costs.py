from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = sorted(path for path in (ROOT / "Sources").glob("*.swift") if path.name != "main.swift")

HARNESS = """
import AppKit

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func describe(_ reading: CostReading) -> Any {
    switch reading {
    case .loading: return "loading"
    case .unavailable: return "unavailable"
    case .usage(let usage):
        return ["today": usage.today, "week": usage.week, "month": usage.month, "models": usage.models] as [String: Any]
    }
}

func views(_ costs: LocalCosts) -> [String: Any] {
    var result = Dictionary(uniqueKeysWithValues: CostView.allCases.map { ($0.rawValue, describe(costs.reading(for: $0))) })
    result["codex"] = describe(costs.codex)
    return result
}

func reading(_ usage: LocalUsage?) -> CostReading {
    usage.map(CostReading.usage) ?? .unavailable
}

let grandeCodex = LocalUsage(today: 1.5, week: 10.25, month: 40, models: ["gpt-6-sol"])
let arguments = CommandLine.arguments
switch arguments[1] {
case "views":
    let claude = LocalUsage(today: 2, week: 20.5, month: 80.75, models: ["OPUS"])
    let codex = LocalUsage(today: 100, week: 200, month: 300, models: ["gpt-6.1-sol"])
    emit([
        "both": views(LocalCosts(codex: .usage(codex), grandeCodex: .usage(grandeCodex), claude: .usage(claude))),
        "claudeLoading": views(LocalCosts(grandeCodex: .usage(grandeCodex), claude: .loading)),
        "grandeCodexUnavailable": views(LocalCosts(grandeCodex: .unavailable, claude: .usage(claude))),
        "unavailableWhileLoading": views(LocalCosts(grandeCodex: .loading, claude: .unavailable)),
        "nothingRead": views(LocalCosts()),
        "withAntigravity": views(LocalCosts(grandeCodex: .usage(grandeCodex), claude: .usage(claude),
                                            antigravity: .usage(LocalUsage(today: 0.5, week: 4, month: 9, models: ["NEON"])))),
        "antigravityLoading": views(LocalCosts(grandeCodex: .usage(grandeCodex), claude: .usage(claude), antigravity: .loading)),
        "antigravityUnavailable": views(LocalCosts(grandeCodex: .usage(grandeCodex), claude: .usage(claude), antigravity: .unavailable))
    ])
case "agy":
    // gdc ag cost --json, priced for a fixed day.
    let data = FileManager.default.contents(atPath: arguments[2])!
    let now = Date(timeIntervalSince1970: Double(arguments[3])!)
    if let reading = AntigravityCost.reading(from: data, now: now) {
        emit(["today": reading.usage.today, "week": reading.usage.week, "month": reading.usage.month,
              "models": reading.usage.models, "unpriced": reading.unpriced, "failed": reading.failed])
    } else {
        emit(["unreadable": true])
    }
case "read":
    // Every cost read from transcripts under a test home.
    let home = arguments[2]
    emit(views(LocalCosts(
        codex: reading(LocalCodexUsage.read(.codex, home: home)),
        grandeCodex: reading(LocalCodexUsage.read(.grandeCodex, home: home)),
        claude: reading(LocalClaudeUsage.read(home: home))
    )))
case "cycle":
    emit([
        "next": Dictionary(uniqueKeysWithValues: CostView.allCases.map { ($0.rawValue, $0.next.rawValue) }),
        "nextWithoutGdc": Dictionary(uniqueKeysWithValues: CostView.allCases.map { ($0.rawValue, $0.next(withAntigravity: false).rawValue) }),
        "default": CostView.resolved(nil).rawValue,
        "storedTotal": CostView.resolved("total").rawValue,
        "storedGrandeCodex": CostView.resolved("grandeCodex").rawValue,
        "storedByTheFirstBuild": CostView.resolved("codex").rawValue
    ])
case "fit":
    _ = NSApplication.shared
    var results: [[String: Any]] = []
    let fiveDigits = "Today $99,999 · Week $99,999 · Month $99,999"
    for (title, chip, amounts) in [
        ("GrandeCodex", true, fiveDigits),
        ("Claude", true, fiveDigits),
        ("Antigravity", true, fiveDigits),
        ("Antigravity", true, "Bugün $99.999 · Hafta $99.999 · Ay $99.999"),
        ("Total", true, fiveDigits),
        ("Toplam", true, "Bugün $99.999 · Hafta $99.999 · Ay $99.999"),
        ("Cost", false, fiveDigits),
        ("Claude", true, "Today $182 · Week $1,406 · Month $4,874"),
        ("Cost", false, "Today $182 · Week $1,406 · Month $4,874")
    ] {
        let footer = CostFooterView()
        // The popover is 325 pt: 12 pt to the footer, then the 19 pt copy button and 10 pt inset.
        footer.frame = NSRect(x: 0, y: 0, width: 325 - 12 - 19 - 10, height: 19)
        let short = amounts.replacingOccurrences(of: "Week", with: "Wk").replacingOccurrences(of: "Month", with: "Mo")
            .replacingOccurrences(of: "Hafta", with: "Hft")
        footer.show(title: title, tint: chip ? .systemBlue : nil, amounts: amounts, shortAmounts: short)
        footer.layoutSubtreeIfNeeded()
        let label = footer.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == amounts || $0.stringValue == short }!
        results.append([
            "title": title,
            "amounts": amounts,
            "shown": label.stringValue,
            "role": footer.accessibilityRole()?.rawValue ?? "",
            "fontSize": label.font!.pointSize,
            "needed": label.fittingSize.width,
            "width": label.frame.width,
            "right": label.frame.maxX,
            "footerWidth": footer.bounds.width
        ])
    }
    emit(results)
default:
    exit(2)
}
"""


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def claude_response(message_id, input_tokens):
    """One assistant line as Claude Code writes it, timestamped now."""
    return json.dumps({
        "type": "assistant",
        "timestamp": stamp(),
        "requestId": f"req_{message_id}",
        "message": {
            "id": message_id,
            "model": "claude-opus-5-5",
            "usage": {"input_tokens": input_tokens, "output_tokens": 0},
        },
    })


def codex_rollout(input_tokens):
    """A Codex rollout transcript: the model, then one token_count, timestamped now."""
    usage = {"input_tokens": input_tokens, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 0}
    events = [
        {"timestamp": stamp(), "type": "turn_context", "payload": {"model": "gpt-6-sol"}},
        {"timestamp": stamp(), "type": "event_msg", "payload": {
            "type": "token_count", "info": {"total_token_usage": usage, "last_token_usage": usage}}},
    ]
    return "".join(json.dumps(event) + "\n" for event in events)


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class LocalCostsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="local-costs-test."))
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

    def run_harness(self, *arguments):
        environment = {key: value for key, value in os.environ.items() if key != "CLAUDE_CONFIG_DIR"}
        output = subprocess.run([str(self.binary), *arguments], check=True, capture_output=True, text=True, env=environment)
        return json.loads(output.stdout)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def amounts(self, reading):
        return [round(reading[key], 6) for key in ("today", "week", "month")]

    def test_grandecodex_claude_and_total_are_kept_apart(self):
        both = self.run_harness("views")["both"]
        self.assertEqual(both["grandeCodex"], {"today": 1.5, "week": 10.25, "month": 40, "models": ["gpt-6-sol"]})
        self.assertEqual(both["claude"], {"today": 2, "week": 20.5, "month": 80.75, "models": ["OPUS"]})
        # Real Codex use never reaches the Claude mode total.
        self.assertEqual(both["total"], {"today": 3.5, "week": 30.75, "month": 120.75, "models": ["OPUS", "gpt-6-sol"]})
        self.assertEqual(both["codex"]["today"], 100)

    def test_total_waits_for_both_and_is_unknown_when_either_is(self):
        views = self.run_harness("views")
        self.assertEqual(views["claudeLoading"]["total"], "loading")
        self.assertEqual(views["claudeLoading"]["grandeCodex"]["today"], 1.5)
        self.assertEqual(views["grandeCodexUnavailable"]["total"], "unavailable")
        self.assertEqual(views["grandeCodexUnavailable"]["claude"]["today"], 2)
        self.assertEqual(views["unavailableWhileLoading"]["total"], "unavailable")
        # Without gdc (no Antigravity reading) the total is GrandeCodex + Claude and Antigravity is unavailable.
        self.assertEqual(views["nothingRead"],
                         {"codex": "loading", "grandeCodex": "loading", "claude": "loading", "antigravity": "unavailable",
                          "total": "loading"})

    def test_total_adds_antigravity_when_it_is_read(self):
        views = self.run_harness("views")
        self.assertEqual(views["withAntigravity"]["total"],
                         {"today": 4.0, "week": 34.75, "month": 129.75, "models": ["NEON", "OPUS", "gpt-6-sol"]})
        self.assertEqual(views["antigravityLoading"]["total"], "loading")
        # An Antigravity cost that cannot be read (Mac mini away) is left out rather than blanking the total.
        self.assertEqual(views["antigravityUnavailable"]["total"],
                         {"today": 3.5, "week": 30.75, "month": 120.75, "models": ["OPUS", "gpt-6-sol"]})
        # GrandeCodex + Claude alone when gdc is not there.
        self.assertEqual(views["both"]["total"]["today"], 3.5)

    def test_antigravity_tokens_are_priced_per_model_and_day(self):
        # 2026-11-26 12:00 local: a Thursday; the week starts on Monday the 23rd.
        now = datetime(2026, 11, 26, 12, 0).timestamp()
        body = {"accounts": [
            {"id": "ag-1", "alias": "talisca", "days": {
                "2026-11-26": {"gemini-4-neon": [1_000_000, 1_000_000, 1_000_000, 3],      # 3 + 0.15 + 15
                               "claude-opus-5-5-high": [1_000_000, 0, 0, 1],              # 4
                               "gpt-oss-120b": [10, 0, 10, 1]},                           # no price
                "2026-11-23": {"gemini-4-argon-trial": [1_000_000, 0, 1_000_000, 2]},     # 2 + 10 (before Dec 1)
                "2026-11-02": {"gemini-pro-orchestrator-neon": [0, 0, 1_000_000, 1]},     # 15, month only
                "2026-10-30": {"gemini-4-neon": [1_000_000, 0, 0, 1]}}},                   # last month: left out
            {"id": "ag-2", "alias": "cenk", "days": {
                "2026-11-26": {"gemini-flash-worker-agy": [1_000_000, 0, 0, 1],            # 0.75 (3.8 Flash)
                               "gemini-4-hydrogen": [0, 1_000_000, 0, 1]}}},              # 0.075
            {"id": "ag-3", "alias": "sosa", "days": None, "error": "ssh: macmini unreachable"}]}
        path = self.work / "agy.json"
        path.write_text(json.dumps(body))
        result = subprocess.run([str(self.binary), "agy", str(path), str(now)], check=True, capture_output=True, text=True)
        got = json.loads(result.stdout)
        self.assertAlmostEqual(got["today"], 3 + 0.15 + 15 + 4 + 0.75 + 0.075)
        self.assertAlmostEqual(got["week"], got["today"] + 12)
        self.assertAlmostEqual(got["month"], got["week"] + 15)
        self.assertEqual(got["unpriced"], ["gpt-oss-120b"])
        self.assertEqual(got["failed"], ["sosa"])
        self.assertEqual(got["models"], ["ARGON", "FLASH", "HYDROGEN", "NEON", "OPUS"])

    def test_argon_costs_more_from_december(self):
        now = datetime(2026, 12, 2, 12, 0).timestamp()
        body = {"accounts": [{"id": "ag-1", "alias": "talisca", "days": {
            "2026-12-02": {"gemini-4-carbon": [1_000_000, 0, 1_000_000, 1]}}}]}
        path = self.work / "agy.json"
        path.write_text(json.dumps(body))
        got = json.loads(subprocess.run([str(self.binary), "agy", str(path), str(now)], check=True, capture_output=True,
                                        text=True).stdout)
        self.assertAlmostEqual(got["today"], 4 + 20)

    def test_no_account_read_is_unavailable(self):
        body = {"accounts": [{"id": "ag-1", "alias": "talisca", "days": None, "error": "down"}]}
        path = self.work / "agy.json"
        path.write_text(json.dumps(body))
        got = json.loads(subprocess.run([str(self.binary), "agy", str(path), "1795700000"], check=True,
                                        capture_output=True, text=True).stdout)
        self.assertEqual(got, {"unreadable": True})

    def test_real_codex_and_grandecodex_read_separate_homes(self):
        home = Path(tempfile.mkdtemp(prefix="home.", dir=self.work))
        # gpt-6-sol input is $2 per million tokens.
        self.write(home / ".codex" / "sessions" / "2026" / "10" / "a.jsonl", codex_rollout(1_000_000))
        self.write(home / "m365bridge-next" / "codex-cli" / "grande" / "sessions" / "b.jsonl", codex_rollout(500_000))
        extra = home / "extra-codex"
        self.write(extra / "sessions" / "c.jsonl", codex_rollout(250_000))
        worker = home / ".codex-workers" / "cx-1" / "codex"
        self.write(worker / "sessions" / "2026" / "10" / "d.jsonl", codex_rollout(1_500_000))
        self.write(worker / "auth.json", '{"tokens": {}}')
        # A profile list that also names a worker home must not pull it into real Codex.
        self.write(home / "m365bridge-next" / "cli-profiles.json",
                   json.dumps({"profiles": [{"codex_home": str(extra)}, {"codex_home": str(worker)}]}))
        # Claude Code: $4 own + $4 from a GrandeClaudex Claude worker (1M input on Opus 5.5 each).
        self.write(home / ".claude" / "projects" / "app" / "own.jsonl", claude_response("msg_own", 1_000_000) + "\n")
        self.write(home / ".claude-accounts" / "kr-worker1" / "projects" / "app" / "job.jsonl",
                   claude_response("msg_worker", 1_000_000) + "\n")

        views = self.run_harness("read", str(home))
        self.assertEqual(self.amounts(views["codex"]), [3.5, 3.5, 3.5])
        self.assertEqual(self.amounts(views["grandeCodex"]), [3.0, 3.0, 3.0])
        self.assertEqual(self.amounts(views["claude"]), [8.0, 8.0, 8.0])
        self.assertEqual(self.amounts(views["total"]), [11.0, 11.0, 11.0])

    def test_no_grandeclaudex_workers_is_no_grandecodex_spend(self):
        home = Path(tempfile.mkdtemp(prefix="home.", dir=self.work))
        self.write(home / ".codex" / "sessions" / "a.jsonl", codex_rollout(1_000_000))
        self.write(home / ".claude" / "projects" / "app" / "own.jsonl", claude_response("msg_own", 1_000_000) + "\n")
        views = self.run_harness("read", str(home))
        self.assertEqual(self.amounts(views["codex"]), [2.0, 2.0, 2.0])
        self.assertEqual(self.amounts(views["grandeCodex"]), [0, 0, 0])
        self.assertEqual(self.amounts(views["total"]), [4.0, 4.0, 4.0])

    def test_clicks_cycle_grandecodex_claude_total_and_start_on_claude(self):
        cycle = self.run_harness("cycle")
        self.assertEqual(cycle["next"], {"grandeCodex": "claude", "claude": "antigravity", "antigravity": "total",
                                         "total": "grandeCodex"})
        # Without gdc there is no Antigravity view to click to.
        # A stored Antigravity view shows as the total there, so its click goes on from the total.
        self.assertEqual(cycle["nextWithoutGdc"], {"grandeCodex": "claude", "claude": "total", "antigravity": "grandeCodex",
                                                   "total": "grandeCodex"})
        self.assertEqual(cycle["default"], "claude")
        self.assertEqual(cycle["storedTotal"], "total")
        self.assertEqual(cycle["storedGrandeCodex"], "grandeCodex")
        # The first build's "codex" meant all Codex homes; it is not carried over.
        self.assertEqual(cycle["storedByTheFirstBuild"], "claude")

    def test_five_digit_amounts_fit_on_one_line(self):
        results = self.run_harness("fit")
        for result in results:
            with self.subTest(title=result["title"], amounts=result["amounts"]):
                self.assertLessEqual(result["needed"], result["width"] + 0.01)
                self.assertLessEqual(result["right"], result["footerWidth"] + 0.01)
                self.assertGreaterEqual(result["fontSize"], 9)
        # Only five digits beside the long GrandeCodex and Antigravity chips need the short period names.
        self.assertEqual([result["title"] for result in results if result["shown"] != result["amounts"]],
                         ["GrandeCodex", "Antigravity"])
        # Everyday amounts keep the usual size, and only the chip is a button.
        self.assertEqual([result["fontSize"] for result in results[-2:]], [10, 10])
        self.assertEqual([result["role"] for result in results[-2:]], ["AXButton", "AXStaticText"])


if __name__ == "__main__":
    unittest.main()
