import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "Sources" / "ClaudeSessionSharing.swift", ROOT / "Sources" / "ClaudeDesktopAccounts.swift"]

HARNESS = """
import Foundation

func emit(_ result: ClaudeSessionSharing.Result) {
    let object: [String: Int] = ["added": result.added, "updated": result.updated, "removed": result.removed, "folders": result.folders]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

let arguments = CommandLine.arguments
let sharing = ClaudeSessionSharing(home: arguments[2])
switch arguments[1] {
case "sync":
    emit(sharing.sync(desktopClosed: arguments[3] == "closed"))
default:
    exit(2)
}
"""

SECOND = 1_000_000_000
ACCOUNT_A = "aaaaaaaa-0000-4000-8000-000000000001"
ACCOUNT_B = "bbbbbbbb-0000-4000-8000-000000000002"
ORG = "0000000a-0000-4000-8000-00000000000a"


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class SessionSharingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="session-sharing-test."))
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

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="home.", dir=self.work))
        self.support = self.home / "Library" / "Application Support"
        self.a = self.folder("Claude", ACCOUNT_A)
        self.b = self.folder("Claude", ACCOUNT_B)

    # Fixtures

    def folder(self, profile, account, org=ORG):
        path = self.support / profile / "claude-code-sessions" / account / org
        path.mkdir(parents=True, exist_ok=True)
        return path

    def write(self, folder, sid, age=60.0, **fields):
        """Writes a session file as Desktop would, `age` seconds old."""
        record = {
            "sessionId": f"local_{sid}",
            "cwd": "/Users/someone/Projects/app",
            "title": "Session",
            "isArchived": False,
            "lastActivityAt": 1_790_000_000_000,
            "remoteControlUserEnabled": True,
            # A nested key with the same name must never be mistaken for the session's own.
            "spawnSeed": {"isArchived": True, "note": 'a "quoted" {brace} [bracket] \\ "isArchived":true'},
        }
        record.update(fields)
        path = folder / f"local_{sid}.json"
        path.write_text(json.dumps(record, separators=(",", ":")))
        stamp = time.time_ns() - int(age * SECOND)
        os.utime(path, ns=(stamp, stamp))
        return path

    def read(self, folder, sid):
        path = folder / f"local_{sid}.json"
        return json.loads(path.read_text()) if path.exists() else None

    def mtime(self, folder, sid):
        return (folder / f"local_{sid}.json").stat().st_mtime_ns

    def sync(self, closed=False):
        result = subprocess.run(
            [str(self.binary), "sync", str(self.home), "closed" if closed else "running"],
            check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout)

    # Closed sync

    def test_running_sync_holds_back_a_copy_still_being_written(self):
        sid = str(uuid.uuid4())
        self.write(self.a, sid, age=0.2, title="Fresh")
        self.assertEqual(self.sync()["added"], 0)
        self.assertIsNone(self.read(self.b, sid))

    def test_closed_sync_copies_what_desktop_flushed_as_it_quit(self):
        sid = str(uuid.uuid4())
        self.write(self.a, sid, age=600, title="Before")
        self.sync()
        self.write(self.a, sid, age=0.2, title="Flushed on quit")
        self.assertEqual(self.sync(closed=True)["updated"], 1)
        self.assertEqual(self.read(self.b, sid)["title"], "Flushed on quit")
        self.assertEqual(self.mtime(self.a, sid), self.mtime(self.b, sid))

    # Claude-3p

    def test_stale_third_party_copy_of_a_scratch_session_never_wins(self):
        third = self.folder("Claude-3p", "cccccccc-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000001")
        sid = str(uuid.uuid4())
        scratch = "/Users/someone/Library/Application Support/Claude/scratch-workspaces/x/y/scratch-1"
        for folder in (self.a, self.b):
            self.write(folder, sid, age=600, cwd=scratch, isArchived=True)
        self.sync()
        before = {folder: self.mtime(folder, sid) for folder in (self.a, self.b)}
        # Desktop in CLIProxy mode saves its old, un-archived copy: the newest file now.
        self.write(third, sid, age=30, cwd=scratch, isArchived=False, title="Stale")
        self.sync()
        for folder in (self.a, self.b):
            self.assertTrue(self.read(folder, sid)["isArchived"])
            self.assertEqual(self.mtime(folder, sid), before[folder])
        self.assertEqual(self.read(third, sid)["title"], "Stale")

    def test_third_party_still_shares_sessions_in_project_folders(self):
        third = self.folder("Claude-3p", "cccccccc-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000001")
        sid = str(uuid.uuid4())
        self.write(self.a, sid, age=600)
        self.write(third, sid, age=30, title="Newer in CLIProxy")
        self.sync()
        self.assertEqual(self.read(self.a, sid)["title"], "Newer in CLIProxy")
        self.assertEqual(self.read(self.b, sid)["title"], "Newer in CLIProxy")


if __name__ == "__main__":
    unittest.main()
