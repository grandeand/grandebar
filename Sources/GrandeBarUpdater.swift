import AppKit
import CryptoKit
import Foundation

@MainActor final class GrandeBarUpdater {
    private let releaseURL = URL(string: "https://api.github.com/repos/grandeand/grandebar/releases/latest")!
    private var checking = false
    private var timer: Timer?

    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.check(manual: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.check(manual: false)
            }
        }
    }

    func check(manual: Bool) {
        guard !checking else { return }
        checking = true
        Task {
            do {
                let release = try await latestRelease()
                checking = false
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                guard release.version.compare(current, options: .numeric) == .orderedDescending else {
                    if manual { show("GrandeBar is up to date", "Installed version: \(current)") }
                    return
                }
                let alert = NSAlert()
                alert.messageText = "GrandeBar \(release.version) is available"
                alert.informativeText = "Download and verify the macOS release, then restart GrandeBar?"
                alert.addButton(withTitle: "Download and Install")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await install(release)
            } catch {
                checking = false
                if manual { show("Update failed", error.localizedDescription) }
            }
        }
    }

    private struct Release {
        let version: String
        let archive: URL
        let checksum: URL
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard url.scheme == "https", ["api.github.com", "github.com", "objects.githubusercontent.com"].contains(url.host ?? "") else {
            throw updateError("Unexpected download address")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= limit else {
            throw updateError("Release download failed or exceeded the size limit")
        }
        return data
    }

    private func latestRelease() async throws -> Release {
        let data = try await fetch(releaseURL, limit: 128 * 1024)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool == false,
              json["prerelease"] as? Bool == false,
              let tag = json["tag_name"] as? String,
              tag.range(of: "^v[0-9]+[.][0-9]+[.][0-9]+$", options: .regularExpression) != nil,
              let assets = json["assets"] as? [[String: Any]] else {
            throw updateError("Invalid release metadata")
        }
        let version = String(tag.dropFirst())
        func asset(_ name: String) -> URL? {
            guard let item = assets.first(where: { $0["name"] as? String == name }),
                  let value = item["browser_download_url"] as? String else { return nil }
            return URL(string: value)
        }
        let filename = "GrandeBar-\(version).zip"
        guard let archive = asset(filename), let checksum = asset(filename + ".sha256") else {
            throw updateError("Release archive or checksum is missing")
        }
        return Release(version: version, archive: archive, checksum: checksum)
    }

    private func install(_ release: Release) async throws {
        let checksumData = try await fetch(release.checksum, limit: 1024)
        guard let checksumText = String(data: checksumData, encoding: .utf8),
              let expected = checksumText.split(whereSeparator: \.isWhitespace).first.map(String.init),
              expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw updateError("Invalid release checksum")
        }
        let archiveData = try await fetch(release.archive, limit: 100 * 1024 * 1024)
        let actual = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw updateError("Release checksum mismatch") }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("grandebar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let zip = temporary.appendingPathComponent("GrandeBar.zip")
        try archiveData.write(to: zip, options: .atomic)
        let extracted = temporary.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        let app = extracted.appendingPathComponent("GrandeBar.app", isDirectory: true)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "co.grande.grandebar",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw updateError("Downloaded application identity or version mismatch")
        }
        guard let installer = Bundle.main.url(forResource: "install-update", withExtension: "sh"),
              FileManager.default.isExecutableFile(atPath: installer.path) else {
            throw updateError("Update installer is missing")
        }
        let target = Bundle.main.bundleURL
        guard target.lastPathComponent == "GrandeBar.app" else { throw updateError("Unexpected installation location") }
        let helper = temporary.appendingPathComponent("install-update.sh")
        try FileManager.default.copyItem(at: installer, to: helper)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path, app.path, target.path, String(ProcessInfo.processInfo.processIdentifier), release.version]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw updateError("Package verification failed") }
    }

    private func updateError(_ message: String) -> NSError {
        NSError(domain: "GrandeBarUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
