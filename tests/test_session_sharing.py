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
    let object: [String: Int] = [
        "added": result.added, "updated": result.updated, "removed": result.removed,
        "folders": result.folders, "failed": result.failed
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

/// Stands in for Claude Desktop: quitting flushes what it still held, i.e. staged *.flush files
/// land with the current time.
final class FakeDesktop: DesktopAppControl {
    let support: URL
    private(set) var isRunning = true
    init(home: String) { support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support") }

    func quitAndWait(timeout: TimeInterval) -> Bool {
        var staged: [URL] = []
        for case let url as URL in FileManager.default.enumerator(at: support, includingPropertiesForKeys: nil)! where url.pathExtension == "flush" {
            staged.append(url)
        }
        for url in staged {
            let path = url.deletingPathExtension().path
            guard rename(url.path, path) == 0, utimes(path, nil) == 0 else { return false }
        }
        isRunning = false
        return true
    }

    func launch() { isRunning = true }
}

let arguments = CommandLine.arguments
let sharing = ClaudeSessionSharing(home: arguments[2])
switch arguments[1] {
case "sync":
    emit(sharing.sync(desktopClosed: arguments[3] == "closed"))
case "switch":
    // GrandeBar's switch: quit Desktop, restore the account, sync while closed, relaunch.
    let desktop = FakeDesktop(home: arguments[2])
    let accounts = ClaudeDesktopAccounts(home: arguments[2], app: desktop)
    var synced = ClaudeSessionSharing.Result()
    try accounts.switchTo(arguments[3]) { synced = sharing.sync(desktopClosed: true) }
    precondition(desktop.isRunning, "Desktop was not relaunched")
    print(accounts.liveAccountUUID() ?? "")
    emit(synced)
default:
    exit(2)
}
"""

SECOND = 1_000_000_000
ACCOUNT_A = "aaaaaaaa-0000-4000-8000-000000000001"
ACCOUNT_B = "bbbbbbbb-0000-4000-8000-000000000002"
ACCOUNT_C = "cccccccc-0000-4000-8000-000000000003"
ACCOUNT_3P = "dddddddd-0000-4000-8000-000000000004"
ORG = "0000000a-0000-4000-8000-00000000000a"
ORG_3P = "00000000-0000-4000-8000-000000000001"
SCRATCH = "/Users/someone/Library/Application Support/Claude/scratch-workspaces/x/y/scratch-1"

WORK = None
BINARY = None


def setUpModule():
    global WORK, BINARY
    if not shutil.which("swiftc"):
        return
    WORK = Path(tempfile.mkdtemp(prefix="session-sharing-test."))
    sources = WORK / "harness"
    sources.mkdir()
    (sources / "main.swift").write_text(HARNESS)
    BINARY = WORK / "harness-bin"
    subprocess.run(["swiftc", *map(str, SOURCES), str(sources / "main.swift"), "-o", str(BINARY)], check=True, capture_output=True)


def tearDownModule():
    if WORK:
        shutil.rmtree(WORK, ignore_errors=True)


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is not available")
class Sandbox(unittest.TestCase):
    """A fake home with Claude Desktop's session folders; GrandeBar's pass runs against it."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="home.", dir=WORK))
        self.support = self.home / "Library" / "Application Support"
        self.a = self.folder("Claude", ACCOUNT_A)
        self.b = self.folder("Claude", ACCOUNT_B)
        self.c = self.folder("Claude", ACCOUNT_C)
        self.folders = [self.a, self.b, self.c]

    def folder(self, profile, account, org=ORG):
        path = self.support / profile / "claude-code-sessions" / account / org
        path.mkdir(parents=True, exist_ok=True)
        return path

    def write(self, folder, sid, age=60.0, suffix="", **fields):
        """Writes a session file as Desktop would, `age` seconds ago."""
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
        path = folder / f"local_{sid}.json{suffix}"
        path.write_text(json.dumps(record, separators=(",", ":")))
        stamp = time.time_ns() - int(age * SECOND)
        os.utime(path, ns=(stamp, stamp))
        return path

    def read(self, folder, sid):
        path = folder / f"local_{sid}.json"
        return json.loads(path.read_text()) if path.exists() else None

    def text(self, folder, sid):
        return (folder / f"local_{sid}.json").read_text()

    def mtime(self, folder, sid):
        return (folder / f"local_{sid}.json").stat().st_mtime_ns

    def archived(self, sid, *folders):
        return [self.read(folder, sid)["isArchived"] for folder in folders]

    def signed_in(self, account, profile="Claude"):
        """Desktop's record of the account it is signed into: that account's folders count as loaded."""
        claude = self.support / "Claude"
        mode = "3p" if profile == "Claude-3p" else "1p"
        (claude / "claude_desktop_config.json").write_text(json.dumps({"deploymentMode": mode}))
        (self.support / profile / "config.json").write_text(json.dumps({"lastKnownAccountUuid": account}))

    def shared(self, age=600, **fields):
        """A session already in every folder, as earlier passes left it."""
        sid = str(uuid.uuid4())
        self.write(self.a, sid, age=age, **fields)
        self.sync(closed=True)
        return sid

    def ledger(self):
        return self.support / "GrandeBar" / "ClaudeSessionArchive.json"

    def sync(self, closed=False):
        result = subprocess.run(
            [str(BINARY), "sync", str(self.home), "closed" if closed else "running"],
            check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout)


class ClosedSyncTests(Sandbox):
    def test_running_sync_holds_back_a_copy_still_being_written(self):
        sid = str(uuid.uuid4())
        self.write(self.a, sid, age=0.2, title="Fresh")
        self.assertEqual(self.sync()["added"], 0)
        self.assertIsNone(self.read(self.b, sid))

    def test_closed_sync_copies_what_desktop_flushed_as_it_quit(self):
        sid = self.shared(title="Before")
        self.write(self.a, sid, age=0.2, title="Flushed on quit")
        self.assertEqual(self.sync(closed=True)["updated"], 2)
        self.assertEqual(self.read(self.b, sid)["title"], "Flushed on quit")
        self.assertEqual(self.mtime(self.a, sid), self.mtime(self.b, sid))

    def test_closed_sync_spreads_an_archive_flushed_as_desktop_quit(self):
        self.signed_in(ACCOUNT_A)
        sid = self.shared()
        self.write(self.a, sid, age=0.2, isArchived=True)
        self.sync()
        self.assertEqual(self.archived(sid, self.b, self.c), [False, False])
        self.sync(closed=True)
        self.assertEqual(self.archived(sid, *self.folders), [True, True, True])


class ThirdPartyTests(Sandbox):
    def setUp(self):
        super().setUp()
        self.third = self.folder("Claude-3p", ACCOUNT_3P, ORG_3P)

    def test_stale_third_party_copy_of_a_scratch_session_never_wins(self):
        sid = self.shared(cwd=SCRATCH, isArchived=True)
        self.assertIsNone(self.read(self.third, sid))
        before = {folder: self.mtime(folder, sid) for folder in self.folders}
        # Desktop in CLIProxy mode saves its old, un-archived copy: the newest file now.
        self.write(self.third, sid, age=30, cwd=SCRATCH, isArchived=False, title="Stale")
        self.sync()
        self.sync(closed=True)
        for folder in self.folders:
            self.assertTrue(self.read(folder, sid)["isArchived"])
            self.assertEqual(self.mtime(folder, sid), before[folder])
        self.assertEqual(self.read(self.third, sid)["title"], "Stale")

    def test_third_party_still_shares_sessions_in_project_folders(self):
        sid = self.shared()
        self.write(self.third, sid, age=30, title="Newer in CLIProxy", isArchived=True)
        self.sync()
        for folder in self.folders:
            self.assertEqual(self.read(folder, sid)["title"], "Newer in CLIProxy")
            self.assertTrue(self.read(folder, sid)["isArchived"])

    def test_third_party_profile_is_left_alone_while_desktop_runs_on_it(self):
        self.signed_in(ACCOUNT_3P, profile="Claude-3p")
        sid = self.shared()
        self.write(self.a, sid, age=30, isArchived=True)
        self.sync()
        self.assertFalse(self.read(self.third, sid)["isArchived"])
        self.assertEqual(self.archived(sid, self.b, self.c), [True, True])


class ArchiveTests(Sandbox):
    def test_stale_save_in_the_loaded_folder_does_not_undo_an_archive(self):
        self.signed_in(ACCOUNT_B)
        sid = self.shared()
        # Archived on A in an earlier run, while Desktop now has B loaded with the old copy.
        self.write(self.a, sid, age=100, isArchived=True, title="Archived on A")
        self.sync()
        self.assertEqual(self.archived(sid, *self.folders), [True, False, True])
        # Desktop saves its in-memory copy of B: newer, but the same isArchived B already held.
        self.write(self.b, sid, age=50, isArchived=False, title="Saved on B")
        self.sync()
        self.assertEqual(self.archived(sid, *self.folders), [True, False, True])
        self.assertEqual(self.read(self.c, sid)["title"], "Saved on B")
        # The switch: Desktop is closed, so B gets the archive too, keeping B's own mtime.
        mtime = self.mtime(self.b, sid)
        self.sync(closed=True)
        self.assertEqual(self.archived(sid, *self.folders), [True, True, True])
        self.assertEqual(self.read(self.b, sid)["title"], "Saved on B")
        self.assertEqual(self.mtime(self.b, sid), mtime)

    def test_unarchive_after_an_archive_wins_and_sets_auto_archive_exempt(self):
        self.signed_in(ACCOUNT_A)
        sid = self.shared()
        self.write(self.a, sid, age=300, isArchived=True)
        self.sync()
        self.assertEqual(self.archived(sid, *self.folders), [True, True, True])
        # Un-archived on B (an earlier CLIProxy or account run), then A, still loaded and
        # unaware of it, saves its archived copy over its own folder.
        self.write(self.b, sid, age=200, isArchived=False)
        self.write(self.a, sid, age=100, isArchived=True, title="Saved on A")
        self.sync()
        for folder in (self.b, self.c):
            session = self.read(folder, sid)
            self.assertFalse(session["isArchived"])
            self.assertTrue(session["autoArchiveExempt"])
            self.assertEqual(session["title"], "Saved on A")
        self.assertTrue(self.read(self.a, sid)["isArchived"])
        self.sync(closed=True)
        self.assertEqual(self.archived(sid, *self.folders), [False, False, False])
        self.assertTrue(self.read(self.a, sid)["autoArchiveExempt"])

    def test_archive_unarchive_archive_across_switches(self):
        self.signed_in(ACCOUNT_A)
        sid = self.shared()
        self.write(self.a, sid, age=300, isArchived=True)
        self.sync()
        self.signed_in(ACCOUNT_B)
        self.sync(closed=True)
        self.write(self.b, sid, age=200, isArchived=False, autoArchiveExempt=True)
        self.sync()
        self.assertEqual(self.archived(sid, *self.folders), [False, False, False])
        self.signed_in(ACCOUNT_A)
        self.sync(closed=True)
        self.write(self.a, sid, age=100, isArchived=True, autoArchiveExempt=True)
        self.sync()
        self.assertEqual(self.archived(sid, *self.folders), [True, True, True])
        self.sync(closed=True)
        self.assertEqual(self.archived(sid, *self.folders), [True, True, True])

    def test_auto_archive_spreads_like_a_manual_one(self):
        self.signed_in(ACCOUNT_A)
        sid = self.shared(lastActivityAt=1_780_000_000_000)
        # Desktop's 7-day rule archives through the same save: only isArchived changes.
        self.write(self.a, sid, age=30, isArchived=True, lastActivityAt=1_780_000_000_000)
        self.sync()
        for folder in (self.b, self.c):
            self.assertEqual(self.read(folder, sid), self.read(self.a, sid))

    def test_delete_beats_archive(self):
        self.signed_in(ACCOUNT_A)
        sid = self.shared()
        self.write(self.a, sid, age=100, isArchived=True)
        self.sync()
        (self.b / f"deleted_{sid}").write_text("1790000000000")
        self.assertEqual(self.sync()["removed"], 3)
        for folder in self.folders:
            self.assertIsNone(self.read(folder, sid))
            self.assertTrue((folder / f"deleted_{sid}").exists())
        # A later save of the session somewhere, archived or not, is deleted again.
        self.write(self.c, sid, age=10, isArchived=False)
        self.assertEqual(self.sync()["removed"], 1)
        self.assertIsNone(self.read(self.c, sid))
        self.assertNotIn(sid, json.loads(self.ledger().read_text())["archive"])

    def test_tombstone_desktop_removed_on_a_cli_import_is_removed_everywhere(self):
        self.signed_in(ACCOUNT_A)
        sid = str(uuid.uuid4())
        (self.a / f"deleted_{sid}").write_text("1790000000000")
        self.sync()
        self.assertTrue(all((folder / f"deleted_{sid}").exists() for folder in self.folders))
        # Desktop imports the CLI session under that id: it drops the tombstone, then saves the
        # session a moment later, possibly with a pass in between.
        (self.a / f"deleted_{sid}").unlink()
        self.sync()
        self.write(self.a, sid, age=5, title="Imported")
        self.sync()
        for folder in self.folders:
            self.assertFalse((folder / f"deleted_{sid}").exists())
            self.assertEqual(self.read(folder, sid)["title"], "Imported")

    def test_first_run_starts_from_the_newest_copy(self):
        newer, tie = str(uuid.uuid4()), str(uuid.uuid4())
        self.write(self.a, newer, age=100, isArchived=True, title="Newest")
        self.write(self.b, newer, age=200, isArchived=False)
        self.write(self.c, newer, age=300, isArchived=False)
        # Equal mtimes that disagree: the first folder in order wins, every time.
        self.write(self.b, tie, age=150, isArchived=False)
        self.write(self.a, tie, age=150, isArchived=True, title="First folder")
        stamp = self.mtime(self.a, tie)
        os.utime(self.b / f"local_{tie}.json", ns=(stamp, stamp))
        self.sync()
        self.assertEqual(self.archived(newer, *self.folders), [True, True, True])
        self.assertEqual(self.read(self.c, newer)["title"], "Newest")
        self.assertEqual(self.archived(tie, *self.folders), [True, True, True])
        self.assertEqual(self.read(self.b, tie)["title"], "First folder")

    def test_repeated_passes_change_nothing(self):
        self.signed_in(ACCOUNT_A)
        kept, archived = self.shared(), self.shared()
        self.write(self.a, archived, age=100, isArchived=True)
        self.sync()
        self.sync(closed=True)
        files = sorted(self.support.rglob("local_*.json"))
        before = {path: (path.stat().st_mtime_ns, path.read_bytes()) for path in files}
        ledger = (self.ledger().stat().st_mtime_ns, self.ledger().read_bytes())
        for closed in (False, True, False):
            result = self.sync(closed=closed)
            self.assertEqual({key: result[key] for key in ("added", "updated", "removed", "failed")},
                             {"added": 0, "updated": 0, "removed": 0, "failed": 0})
        self.assertEqual({path: (path.stat().st_mtime_ns, path.read_bytes()) for path in files}, before)
        self.assertEqual((self.ledger().stat().st_mtime_ns, self.ledger().read_bytes()), ledger)
        self.assertEqual(self.archived(kept, *self.folders), [False, False, False])

    def test_only_the_archive_values_change_in_a_patched_copy(self):
        self.signed_in(ACCOUNT_B)
        sid = self.shared()
        self.write(self.a, sid, age=200, isArchived=True)
        self.sync()
        self.write(self.b, sid, age=100, isArchived=False, title="Saved on B")
        self.sync()
        source = self.text(self.b, sid)
        self.assertEqual(self.text(self.c, sid), source.replace('"isArchived":false', '"isArchived":true', 1))
        self.assertTrue(self.read(self.c, sid)["spawnSeed"]["isArchived"])

    def test_a_patched_unarchive_adds_auto_archive_exempt_and_nothing_else(self):
        self.signed_in(ACCOUNT_A)
        sid = self.shared()
        self.write(self.a, sid, age=300, isArchived=True)
        self.sync()
        self.write(self.b, sid, age=200, isArchived=False)
        self.write(self.a, sid, age=100, isArchived=True, title="Saved on A")
        self.sync()
        source = self.text(self.a, sid)
        expected = '{"autoArchiveExempt":true,' + source[1:].replace('"isArchived":true', '"isArchived":false', 1)
        self.assertEqual(self.text(self.c, sid), expected)

    def test_signed_in_folder_waits_while_desktop_runs(self):
        self.signed_in(ACCOUNT_A)
        sid = self.shared()
        before = self.mtime(self.a, sid)
        self.write(self.b, sid, age=30, title="Newer on B")
        self.sync()
        self.assertEqual(self.mtime(self.a, sid), before)
        self.assertEqual(self.read(self.c, sid)["title"], "Newer on B")
        self.sync(closed=True)
        self.assertEqual(self.read(self.a, sid)["title"], "Newer on B")

    def test_a_failed_write_is_tried_again(self):
        self.signed_in(ACCOUNT_A)
        sid = self.shared()
        self.write(self.a, sid, age=30, isArchived=True)
        self.c.chmod(0o500)
        try:
            self.assertEqual(self.sync()["failed"], 1)
            self.assertFalse(self.read(self.c, sid)["isArchived"])
        finally:
            self.c.chmod(0o700)
        self.assertEqual(self.sync()["updated"], 1)
        self.assertTrue(self.read(self.c, sid)["isArchived"])


class SwitchFlowTests(Sandbox):
    """The account switch end to end on fake folders: ClaudeDesktopAccounts.switchTo with a fake
    Desktop, running the same closed sync GrandeBar runs while Desktop is closed."""

    def setUp(self):
        super().setUp()
        accounts = self.support / "GrandeBar" / "ClaudeDesktop" / "accounts"
        for alias, account in (("a", ACCOUNT_A), ("b", ACCOUNT_B)):
            profile = accounts / alias
            (profile / "desktop-state").mkdir(parents=True)
            (profile / "meta.json").write_text(json.dumps({"accountUuid": account, "label": alias}))
            (profile / "config-tokenCacheV2").write_text(f"encrypted-{alias}")
        config = {"lastKnownAccountUuid": ACCOUNT_A, "oauth:tokenCacheV2": "encrypted-a"}
        (self.support / "Claude" / "config.json").write_text(json.dumps(config))

    def switch(self, alias):
        result = subprocess.run([str(BINARY), "switch", str(self.home), alias], check=True, capture_output=True, text=True)
        live, synced = result.stdout.splitlines()
        return live, json.loads(synced)

    def test_switches_carry_every_archive_action(self):
        old, flushed = self.shared(), self.shared()
        # On A: one session archived long ago, one archived right before the switch, which Desktop
        # only writes as it quits.
        self.write(self.a, old, age=300, isArchived=True)
        self.sync()
        self.write(self.a, flushed, suffix=".flush", isArchived=True)
        live, _ = self.switch("b")
        self.assertEqual(live, ACCOUNT_B)
        for sid in (old, flushed):
            self.assertEqual(self.archived(sid, *self.folders), [True, True, True])
        # On B: Desktop loaded the archived copies; un-archiving one spreads while B runs.
        self.write(self.b, old, age=5, isArchived=False, autoArchiveExempt=True)
        self.sync()
        self.assertEqual(self.archived(old, *self.folders), [False, False, False])
        # Back on A, and passes after that, nothing reverts.
        live, _ = self.switch("a")
        self.assertEqual(live, ACCOUNT_A)
        self.sync()
        self.assertEqual(self.archived(old, *self.folders), [False, False, False])
        self.assertEqual(self.archived(flushed, *self.folders), [True, True, True])
        self.assertEqual(json.loads((self.support / "Claude" / "config.json").read_text())["oauth:tokenCacheV2"], "encrypted-a")


if __name__ == "__main__":
    unittest.main()
