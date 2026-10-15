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
import Foundation

guard let usage = LocalClaudeUsage.read(home: CommandLine.arguments[1]) else {
    print("null")
    exit(0)
}
print(String(format: "%.4f %.4f %.4f", usage.today, usage.week, usage.month))
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
class ClaudeCostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="claude-cost-test."))
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

    def transcript(self, path, *lines):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(line + "\n" for line in lines))

    def cost(self, home):
        environment = {key: value for key, value in os.environ.items() if key != "CLAUDE_CONFIG_DIR"}
        output = subprocess.run([str(self.binary), str(home)], check=True, capture_output=True, text=True, env=environment)
        return [float(value) for value in output.stdout.split()]

    def test_grandeclaudex_worker_transcripts_are_counted_once(self):
        home = Path(tempfile.mkdtemp(prefix="home.", dir=self.work))
        # $4 each: 1M input tokens on Opus 5.5.
        own, worker = response("msg_own", "req_own", 1_000_000), response("msg_worker", "req_worker", 1_000_000)
        self.transcript(home / ".claude" / "projects" / "app" / "own.jsonl", own)
        accounts = home / ".claude-accounts"
        self.transcript(accounts / "kr-worker1" / "projects" / "app" / "job.jsonl", worker)
        # The same response again in a subagent transcript and under another worker: one response.
        self.transcript(accounts / "kr-worker1" / "projects" / "app" / "job" / "subagents" / "agent-1.jsonl", worker)
        self.transcript(accounts / "kr-worker2" / "projects" / "other" / "copy.jsonl", worker)
        # Not transcripts: never read, even when they look like one.
        self.transcript(accounts / "kr-worker1" / "history.jsonl", response("msg_history", "req_history", 9_000_000))
        (accounts / "kr-worker1" / ".credentials.json").write_text('{"claudeAiOauth": {}}')
        (accounts / "kr-worker2" / "settings.json").write_text("{}")
        self.assertEqual(self.cost(home), [8.0, 8.0, 8.0])

    def test_without_workers_only_the_own_transcripts_count(self):
        home = Path(tempfile.mkdtemp(prefix="home.", dir=self.work))
        self.transcript(home / ".claude" / "projects" / "app" / "own.jsonl", response("msg_own", "req_own", 1_000_000))
        self.assertEqual(self.cost(home), [4.0, 4.0, 4.0])


if __name__ == "__main__":
    unittest.main()
