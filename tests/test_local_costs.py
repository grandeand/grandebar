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
    Dictionary(uniqueKeysWithValues: CostView.allCases.map { ($0.rawValue, describe(costs.reading(for: $0))) })
}

let codex = LocalUsage(today: 1.5, week: 10.25, month: 40, models: ["gpt-6.1-sol"])
let arguments = CommandLine.arguments
switch arguments[1] {
case "views":
    let claude = LocalUsage(today: 2, week: 20.5, month: 80.75, models: ["OPUS"])
    emit([
        "both": views(LocalCosts(codex: .usage(codex), claude: .usage(claude))),
        "claudeLoading": views(LocalCosts(codex: .usage(codex), claude: .loading)),
        "codexUnavailable": views(LocalCosts(codex: .unavailable, claude: .usage(claude))),
        "unavailableWhileLoading": views(LocalCosts(codex: .loading, claude: .unavailable)),
        "nothingRead": views(LocalCosts())
    ])
case "read":
    // The Claude side read from transcripts, GrandeClaudex workers included.
    let claude = LocalClaudeUsage.read(home: arguments[2]).map(CostReading.usage) ?? .unavailable
    emit(views(LocalCosts(codex: .usage(codex), claude: claude)))
case "cycle":
    emit([
        "next": Dictionary(uniqueKeysWithValues: CostView.allCases.map { ($0.rawValue, $0.next.rawValue) }),
        "defaultCodexMode": CostView.resolved(nil, claudeMode: false).rawValue,
        "defaultClaudeMode": CostView.resolved(nil, claudeMode: true).rawValue,
        "storedTotal": CostView.resolved("total", claudeMode: false).rawValue,
        "storedCodexInClaudeMode": CostView.resolved("codex", claudeMode: true).rawValue,
        "unknown": CostView.resolved("cost", claudeMode: true).rawValue
    ])
case "fit":
    _ = NSApplication.shared
    var results: [[String: Any]] = []
    for (title, amounts) in [
        ("Codex", "Today $99,999 · Week $99,999 · Month $99,999"),
        ("Claude", "Today $99,999 · Week $99,999 · Month $99,999"),
        ("Total", "Today $99,999 · Week $99,999 · Month $99,999"),
        ("Toplam", "Bugün $99.999 · Hafta $99.999 · Ay $99.999"),
        ("Claude", "Today $182 · Week $1,406 · Month $4,874")
    ] {
        let footer = CostFooterView()
        // The popover is 325 pt: 12 pt to the footer, then the 19 pt copy button and 10 pt inset.
        footer.frame = NSRect(x: 0, y: 0, width: 325 - 12 - 19 - 10, height: 19)
        footer.show(title: title, tint: .systemBlue, amounts: amounts)
        footer.layoutSubtreeIfNeeded()
        let label = footer.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == amounts }!
        results.append([
            "title": title,
            "amounts": amounts,
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


def response(message_id, request_id, input_tokens):
    """One assistant line as Claude Code writes it, timestamped now."""
    stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return json.dumps({
        "type": "assistant",
        "timestamp": stamp,
        "requestId": request_id,
        "message": {
            "id": message_id,
            "model": "claude-opus-5-5",
            "usage": {"input_tokens": input_tokens, "output_tokens": 0},
        },
    })


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

    def test_codex_claude_and_total_are_kept_apart(self):
        both = self.run_harness("views")["both"]
        self.assertEqual(both["codex"], {"today": 1.5, "week": 10.25, "month": 40, "models": ["gpt-6.1-sol"]})
        self.assertEqual(both["claude"], {"today": 2, "week": 20.5, "month": 80.75, "models": ["OPUS"]})
        self.assertEqual(both["total"], {"today": 3.5, "week": 30.75, "month": 120.75, "models": ["OPUS", "gpt-6.1-sol"]})

    def test_total_waits_for_both_and_is_unknown_when_either_is(self):
        views = self.run_harness("views")
        self.assertEqual(views["claudeLoading"]["total"], "loading")
        self.assertEqual(views["claudeLoading"]["claude"], "loading")
        self.assertEqual(views["claudeLoading"]["codex"]["today"], 1.5)
        self.assertEqual(views["codexUnavailable"]["total"], "unavailable")
        self.assertEqual(views["codexUnavailable"]["codex"], "unavailable")
        self.assertEqual(views["codexUnavailable"]["claude"]["today"], 2)
        self.assertEqual(views["unavailableWhileLoading"]["total"], "unavailable")
        self.assertEqual(views["nothingRead"], {"codex": "loading", "claude": "loading", "total": "loading"})

    def test_total_adds_the_claude_transcripts_and_workers_to_codex(self):
        home = Path(tempfile.mkdtemp(prefix="home.", dir=self.work))
        # $4 each: 1M input tokens on Opus 5.5; one in ~/.claude, one under a GrandeClaudex worker.
        own = home / ".claude" / "projects" / "app" / "own.jsonl"
        worker = home / ".claude-accounts" / "kr-worker1" / "projects" / "app" / "job.jsonl"
        for path, line in ((own, response("msg_own", "req_own", 1_000_000)),
                           (worker, response("msg_worker", "req_worker", 1_000_000))):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(line + "\n")
        views = self.run_harness("read", str(home))
        self.assertEqual([views["claude"][key] for key in ("today", "week", "month")], [8, 8, 8])
        self.assertEqual([views["total"][key] for key in ("today", "week", "month")], [9.5, 18.25, 48])

    def test_clicks_cycle_codex_claude_total_and_default_follows_the_mode(self):
        cycle = self.run_harness("cycle")
        self.assertEqual(cycle["next"], {"codex": "claude", "claude": "total", "total": "codex"})
        self.assertEqual(cycle["defaultCodexMode"], "codex")
        self.assertEqual(cycle["defaultClaudeMode"], "claude")
        self.assertEqual(cycle["storedTotal"], "total")
        self.assertEqual(cycle["storedCodexInClaudeMode"], "codex")
        self.assertEqual(cycle["unknown"], "claude")

    def test_five_digit_amounts_fit_on_one_line(self):
        results = self.run_harness("fit")
        for result in results:
            with self.subTest(title=result["title"], amounts=result["amounts"]):
                self.assertLessEqual(result["needed"], result["width"] + 0.01)
                self.assertLessEqual(result["right"], result["footerWidth"] + 0.01)
                self.assertGreaterEqual(result["fontSize"], 9)
        # Everyday amounts keep the usual size.
        self.assertEqual(results[-1]["fontSize"], 10)


if __name__ == "__main__":
    unittest.main()
