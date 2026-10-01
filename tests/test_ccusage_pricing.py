import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "Resources" / "ccusage.json"


class CodexPricingTests(unittest.TestCase):
    def test_override_scopes_match(self):
        config = json.loads(CONFIG.read_text())
        self.assertEqual(
            config["defaults"]["pricingOverrides"]["gpt-6.1-sol"],
            config["codex"]["defaults"]["pricingOverrides"]["gpt-6.1-sol"],
        )

    def test_standard_cost_includes_cached_tokens(self):
        executable = os.environ.get("CCUSAGE_BIN") or shutil.which("ccusage")
        self.assertIsNotNone(executable, "Install ccusage or set CCUSAGE_BIN")
        for model, expected_cost in (("gpt-6.1-sol", 4.43), ("gpt-6-sol", 4.46)):
            with self.subTest(model=model), tempfile.TemporaryDirectory() as home:
                sessions = Path(home) / "sessions" / "2026" / "10" / "01"
                sessions.mkdir(parents=True)
                timestamp = "2026-10-01T00:00:00.000Z"
                session_id = "00000000-0000-4000-8000-000000000001"
                usage = {
                    "input_tokens": 2_000_000,
                    "cached_input_tokens": 300_000,
                    "cache_write_input_tokens": 0,
                    "output_tokens": 100_000,
                    "reasoning_output_tokens": 20_000,
                    "total_tokens": 2_100_000,
                }
                events = [
                    {
                        "type": "session_meta",
                        "payload": {
                            "id": session_id,
                            "timestamp": timestamp,
                            "cwd": home,
                            "originator": "codex_cli_rs",
                            "cli_version": "0.158.0",
                            "source": "cli",
                            "model_provider": "openai",
                        },
                    },
                    {"type": "turn_context", "payload": {"model": model}},
                    {
                        "type": "event_msg",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": usage,
                                "last_token_usage": usage,
                                "model_context_window": 950_000,
                            },
                        },
                    },
                ]
                session = sessions / f"rollout-2026-10-01T00-00-00-{session_id}.jsonl"
                session.write_text(
                    "".join(
                        json.dumps({"timestamp": timestamp, **event}, separators=(",", ":")) + "\n"
                        for event in events
                    )
                )
                result = subprocess.run(
                    [
                        executable, "codex", "daily", "--json", "--offline",
                        "--speed", "standard", "--timezone", "Europe/Istanbul",
                        "--config", str(CONFIG),
                    ],
                    env={**os.environ, "CODEX_HOME": home},
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=30,
                )
                report = json.loads(result.stdout)
                self.assertAlmostEqual(report["totals"]["costUSD"], expected_cost)
                self.assertEqual(report["totals"]["totalTokens"], usage["total_tokens"])
                self.assertIn(model, report["daily"][0]["models"])


if __name__ == "__main__":
    unittest.main()
