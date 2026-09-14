import AppKit
import CryptoKit
import Foundation

/// A small GitHub Releases updater. Releases are published by `.github/workflows/release.yml`,
/// so checking, downloading, and installing updates does not require an app server.
@MainActor
final class UpdateController {
    private let repository = "Zaydo123/greptile-hud"
    private let archiveName = "GreptileHUD.zip"
    private var checking = false

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        do {
            let release = try await latestRelease()
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let available = normalizedVersion(release.tagName)

            guard current.compare(available, options: .numeric) == .orderedAscending else {
                if userInitiated {
                    showAlert(title: "Greptile HUD is up to date",
                              message: "You’re running the latest version (\(current)).")
                }
                return
            }

            let response = showUpdatePrompt(current: current, version: available,
                                            notes: release.body)
            switch response {
            case .alertFirstButtonReturn:
                do {
                    try await downloadAndInstall(release: release, version: available)
                } catch {
                    // The prompt makes this a user-visible install even when the check was
                    // automatic, so installation failures should never disappear silently.
                    showAlert(title: "Couldn’t install the update", message: error.localizedDescription)
                }
            case .alertThirdButtonReturn:
                NSWorkspace.shared.open(release.htmlURL)
            default:
                break
            }
        } catch {
            if userInitiated {
                if case UpdateError.noReleases = error {
                    // First install with no release published yet isn't an error.
                    showAlert(title: "Greptile HUD is up to date",
                              message: "No update has been published yet — you’re on the current build.")
                } else {
                    showAlert(title: "Couldn’t check for updates", message: error.localizedDescription)
                }
            }
        }
    }

    private func latestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\\(repository)/releases/latest") else {
            throw UpdateError.invalidRelease
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GreptileHUD-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError.noReleases }   // no published release yet → current
        try validateHTTP(response)
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func downloadAndInstall(release: Release, version: String) async throws {
        guard let archive = release.assets.first(where: { $0.name == archiveName }),
              let checksum = release.assets.first(where: { $0.name == "\(archiveName).sha256" }) else {
            throw UpdateError.missingAssets
        }

        let archiveData = try await downloadWithRetry(archive.downloadURL)
        let checksumData = try await downloadWithRetry(checksum.downloadURL)
        guard let expected = String(data: checksumData, encoding: .utf8)?
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              expected.caseInsensitiveCompare(sha256(archiveData)) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("GreptileHUD-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let zip = work.appendingPathComponent(archiveName)
            try archiveData.write(to: zip, options: .atomic)
            try run("/usr/bin/ditto", arguments: ["-x", "-k", zip.path, work.path])

            let newApp = work.appendingPathComponent("GreptileHUD.app", isDirectory: true)
            try validate(app: newApp, expectedVersion: version)
            try stageAndRelaunch(newApp: newApp, workDirectory: work)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host?.lowercased() == "github.com",
              url.path.hasPrefix("/\\(repository)/releases/download/") else {
            throw UpdateError.invalidRelease
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validateHTTP(response)
        return data
    }

    /// Downloads are the download step most likely to hit a transient network
    /// blip, so retry twice with a short backoff before surfacing a failure.
    /// The SHA-256 check still runs on every successful fetch, so a partial
    /// retry can't slip a corrupt archive through.
    private func downloadWithRetry(_ url: URL) async throws -> Data {
        for attempt in 1..<4 {
            do {
                return try await download(url)
            } catch {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
            }
        }
        throw UpdateError.downloadFailed
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }
    }

    private func validate(app url: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              normalizedVersion(version) == normalizedVersion(expectedVersion) else {
            throw UpdateError.invalidApplication
        }
        try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", url.path])
    }

    private func stageAndRelaunch(newApp: URL, workDirectory: URL) throws {
        let fm = FileManager.default
        let destination = Bundle.main.bundleURL.standardizedFileURL
        guard destination.pathExtension == "app" else { throw UpdateError.notRunningFromApp }

        let parent = destination.deletingLastPathComponent()
        let token = UUID().uuidString
        let staged = parent.appendingPathComponent(".GreptileHUD-update-\(token).app", isDirectory: true)
        let backup = parent.appendingPathComponent(".GreptileHUD-backup-\(token).app", isDirectory: true)
        try fm.copyItem(at: newApp, to: staged)

        // Wait until this process exits, atomically swap the bundles, and relaunch.
        // After swapping we check that the new app actually stays resident; if it
        // never comes up we roll back to the previous build and relaunch that, so a
        // bad release can't leave the user with no HUD at all. Positional shell
        // arguments keep file paths out of the script itself.
        let script = #"""
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$2" "$4" && mv "$3" "$2"; then
          /usr/bin/open "$2"
          launched=""
          i=0
          while [ -z "$launched" ] && [ "$i" -lt 50 ]; do
            if pgrep -f "$2/Contents/MacOS/GreptileHUD" >/dev/null 2>&1; then
              launched=1
            else
              i=$((i+1)); sleep 0.2
            fi
          done
          if [ -n "$launched" ]; then
            rm -rf "$4" "$5"
          else
            mv "$2" "$5/failed-new.app" 2>/dev/null
            mv "$4" "$2"
            /usr/bin/open "$2"
            rm -rf "$5"
          fi
        else
          test -e "$4" && mv "$4" "$2"
          rm -rf "$3" "$5"
        fi
        """#
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/sh")
        installer.arguments = ["-c", script, "greptile-hud-updater",
                               String(ProcessInfo.processInfo.processIdentifier),
                               destination.path, staged.path, backup.path, workDirectory.path]
        try installer.run()
        NSApp.terminate(nil)
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.commandFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedVersion(_ value: String) -> String {
        String(value.drop(while: { $0 == "v" || $0 == "V" }))
    }

    private func showUpdatePrompt(current: String, version: String, notes: String?) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Greptile HUD \\(version) is available"
        var info = "You’re on \\(current). The update is downloaded from GitHub Releases, verified against its SHA-256 checksum and the bundle’s identity, version, and signature, then installed and the app reopens."
        if let n = notes, !n.isEmpty {
            let clean = whatIsNew(n)
            if !clean.isEmpty {
                info += "\n\nWhat’s new:\n\\(clean)"
            }
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "View on GitHub")
        return alert.runModal()
    }

    /// Release notes are GitHub Markdown — collapse to non-empty lines and cap
    /// the length so the prompt stays readable.
    private func whatIsNew(_ body: String) -> String {
        let clean = body.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return clean.count > 600 ? String(clean.prefix(600)) : clean
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum UpdateError: LocalizedError {
    case invalidRelease
    case missingAssets
    case checksumMismatch
    case badResponse
    case invalidApplication
    case notRunningFromApp
    case noReleases
    case downloadFailed
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "GitHub returned an invalid release."
        case .missingAssets: return "The release is missing GreptileHUD.zip or its checksum."
        case .checksumMismatch: return "The downloaded update did not match its SHA-256 checksum."
        case .badResponse: return "GitHub returned an unexpected response."
        case .invalidApplication: return "The downloaded app failed identity, version, or code-signing validation."
        case .notRunningFromApp: return "Updates can only be installed when Greptile HUD is launched from GreptileHUD.app."
        case .noReleases: return "No release has been published for this repository yet."
        case .downloadFailed: return "Couldn’t download the update from GitHub after several attempts."
        case .commandFailed(let detail): return detail.isEmpty ? "The update helper failed." : detail
        }
    }
}
