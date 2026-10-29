import AppKit
import Combine
import Foundation

// MARK: - API shapes (backend: greptilehud/backend, see backend/README.md)

struct VCUser: Codable, Equatable {
    var id: Int64
    var login: String
    var name: String?
    var lastSeen: Date?
    var createdAt: Date?
    var avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, login, name
        case lastSeen = "last_seen"
        case createdAt = "created_at"
        case avatarUrl = "avatar_url"
    }
}

/// Absolute URL for a backend-relative avatar path ("/api/avatar?login=…&v=…").
func vcAvatarURL(_ path: String?) -> URL? {
    guard let path, !path.isEmpty else { return nil }
    return URL(string: path, relativeTo: VibecodersStore.apiBaseURL)?.absoluteURL
}

/// One app/site bucket from `/api/usage` (or `/api/usage/crew`).
struct VCUsageItem: Codable, Equatable, Identifiable {
    var key: String
    var label: String
    var category: String
    var seconds: Int64
    var people: Int?
    var id: String { key }
}

struct VCUsageReport: Codable, Equatable {
    var totalSeconds: Int64
    var items: [VCUsageItem]
    enum CodingKeys: String, CodingKey {
        case items
        case totalSeconds = "total_seconds"
    }
}

/// Devtime for one crew day ("2026-10-27").
struct VCDay: Codable, Equatable, Identifiable {
    var day: String
    var seconds: Int64
    var id: String { day }
}

/// Status time per activity emoji within a period.
struct VCActivityTotal: Codable, Equatable, Identifiable {
    var emoji: String
    var seconds: Int64
    var count: Int
    var id: String { emoji }
}

/// A completed status, as stored server-side.
struct VCStatusEntry: Codable, Equatable, Identifiable {
    var id: String
    var emoji: String
    var message: String
    var startedAt: Date
    var endedAt: Date

    var displayLabel: String { ActivityPreset.displayLabel(emoji: emoji, message: message) }

    enum CodingKeys: String, CodingKey {
        case id, emoji, message
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

struct VCCrewProfile: Equatable {
    var user: VCUser
    var period: VCLeaderboardPeriod
    var devtimePeriod: Int64
    var devtimeAll: Int64
    var online: Bool
    var sprints: [VCSprint]
    var periodStart: Date?
    var periodEnd: Date?
    var daily: [VCDay] = []
    var activities: [VCActivityTotal] = []
    var usage: VCUsageReport?
    var recentStatuses: [VCStatusEntry] = []
}

struct VCSprint: Codable, Equatable, Identifiable {
    var id: Int64
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: Int64
    var active: Bool

    enum CodingKeys: String, CodingKey {
        case id, active
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
    }
}

enum VCLeaderboardPeriod: String, CaseIterable, Identifiable {
    case today
    case week
    case month

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var profileLabel: String {
        switch self {
        case .today: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        }
    }
}

struct VCOnlineUser: Codable, Equatable {
    var login: String
    var name: String?
    var lastSeen: Date?
    var devtimeToday: Int64
    var avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case login, name
        case lastSeen = "last_seen"
        case devtimeToday = "devtime_today"
        case avatarUrl = "avatar_url"
    }
}

/// A crew member's explicitly running status. Unlike presence, this remains
/// visible while the person is away from their keyboard.
struct VCCrewStatus: Codable, Equatable, Identifiable {
    var login: String
    var name: String?
    var emoji: String
    var message: String
    var startedAt: Date
    var online: Bool
    var avatarUrl: String?

    var id: String { login.lowercased() }

    var displayLabel: String { ActivityPreset.displayLabel(emoji: emoji, message: message) }

    enum CodingKeys: String, CodingKey {
        case login, name, emoji, message, online
        case startedAt = "started_at"
        case avatarUrl = "avatar_url"
    }
}

struct VCLeaderboardEntry: Codable, Equatable {
    var rank: Int
    var login: String
    var name: String?
    var value: Int64
    var online: Bool
    var lastSeen: Date?
    var avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case rank, login, name, value, online
        case lastSeen = "last_seen"
        case avatarUrl = "avatar_url"
    }
}

enum VCError: Error {
    case notFound
    case failed(String)
}

func vcFriendly(_ error: Error) -> String {
    if let e = error as? VCError {
        switch e {
        case .notFound: return "Not on the leaderboard yet — open an editor to start banking devtime"
        case .failed(let msg): return msg
        }
    }
    return error.localizedDescription
}

func vcDuration(_ seconds: Int64) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "\(s)s"
}

/// The backend emits `""` (not null) when a user has no display name; treat
/// nil and whitespace-only names as absent so UI falls back to the login.
func vcDisplayName(_ name: String?) -> String? {
    guard let name else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func vcPeriodRange(start: Date?, end: Date?, timezone: String = "America/Chicago") -> String? {
    guard let start, let end, end > start else { return nil }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)
    let first = formatter.string(from: start)
    let last = formatter.string(from: end.addingTimeInterval(-1))
    return first == last ? "\(first) · \(timezone)" : "\(first) – \(last) · \(timezone)"
}

func vcExactPeriodDescription(_ label: String, start: Date?, end: Date?, timezone: String = "America/Chicago") -> String {
    guard let start, let end else { return "\(label) is measured in \(timezone)." }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)
    return "\(label) starts at \(formatter.string(from: start)) and ends just before \(formatter.string(from: end)) \(timezone)."
}

// MARK: - Store

@MainActor
final class VibecodersStore: NSObject, ObservableObject {
    /// Production by default; `VC_API_URL` points a dev build at a local backend.
    static let apiBaseURL: URL = {
        if let raw = ProcessInfo.processInfo.environment["VC_API_URL"],
           let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return URL(string: "https://greptile-hud.onrender.com")!
    }()

    @Published private(set) var user: VCUser?
    @Published private(set) var online: [VCOnlineUser] = []
    @Published private(set) var crewStatuses: [VCCrewStatus] = []
    @Published private(set) var board: [VCLeaderboardEntry] = []
    @Published private(set) var leaderboardPeriod: VCLeaderboardPeriod = .today
    @Published private(set) var leaderboardPeriodStart: Date?
    @Published private(set) var leaderboardPeriodEnd: Date?
    @Published private(set) var leaderboardTimezone = "America/Chicago"
    @Published private(set) var boardRefreshing = false
    @Published private(set) var devtimeToday: Int64 = 0
    @Published private(set) var todayPeriodEnd: Date?
    @Published private(set) var todayTimezone = "America/Chicago"
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var selectedProfileLogin: String?
    @Published private(set) var crewProfile: VCCrewProfile?
    @Published private(set) var profileLoading = false
    @Published private(set) var profileError: String?
    @Published private(set) var statusSyncing = false
    @Published private(set) var statusError: String?
    @Published private(set) var crewUsage: VCUsageReport?
    @Published private(set) var avatarBusy = false
    @Published private(set) var avatarError: String?
    @Published var usageSharing: Bool = UsageTracker.isEnabled {
        didSet { UsageTracker.isEnabled = usageSharing }
    }
    @Published var errorText: String?

    private static let usernameKey = "vibecoders.username"
    private var statusSyncTask: Task<Void, Never>?
    private var statusSyncRevision = 0

    var username: String { UserDefaults.standard.string(forKey: Self.usernameKey) ?? "" }
    var hasUsername: Bool { !username.isEmpty }
    var todayPeriodDescription: String {
        guard let end = todayPeriodEnd else { return "Today is measured in Central Time." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Today is measured in \(todayTimezone) and resets at \(formatter.string(from: end)) in your local time."
    }
    var leaderboardPeriodDescription: String {
        vcExactPeriodDescription(leaderboardPeriod.profileLabel,
                                 start: leaderboardPeriodStart,
                                 end: leaderboardPeriodEnd,
                                 timezone: leaderboardTimezone)
    }
    var leaderboardPeriodRange: String? {
        vcPeriodRange(start: leaderboardPeriodStart,
                      end: leaderboardPeriodEnd,
                      timezone: leaderboardTimezone)
    }

    // MARK: Identity — trust-based, the user just picks a name

    static func normalizeUsername(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("@") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 32 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let first = s.first, first.isLetter || first.isNumber else { return nil }
        return s.lowercased()   // the backend matches case-insensitively anyway
    }

    func setUsername(_ raw: String) {
        guard let cleaned = Self.normalizeUsername(raw) else {
            errorText = "Pick a username: letters, numbers, - and _ (max 32 characters)"
            return
        }
        let previous = username
        if !previous.isEmpty && previous.caseInsensitiveCompare(cleaned) != .orderedSame {
            enqueueStatus(nil, username: previous, reportErrors: false)
        }
        UserDefaults.standard.set(cleaned, forKey: Self.usernameKey)
        user = nil
        online = []
        crewStatuses = []
        board = []
        leaderboardPeriod = .today
        leaderboardPeriodStart = nil
        leaderboardPeriodEnd = nil
        devtimeToday = 0
        todayPeriodEnd = nil
        dismissProfile()
        statusError = nil
        errorText = nil
        Task { await refresh() }
    }

    func clearUsername() {
        let previous = username
        if !previous.isEmpty {
            enqueueStatus(nil, username: previous, reportErrors: false)
        }
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        user = nil
        online = []
        crewStatuses = []
        board = []
        leaderboardPeriod = .today
        leaderboardPeriodStart = nil
        leaderboardPeriodEnd = nil
        devtimeToday = 0
        todayPeriodEnd = nil
        dismissProfile()
        statusError = nil
        errorText = nil
    }

    // MARK: Crew profiles

    func showProfile(login: String) {
        selectedProfileLogin = login
        crewProfile = nil
        profileError = nil
        profileLoading = true
        Task { await loadProfile(login: login) }
    }

    func dismissProfile() {
        selectedProfileLogin = nil
        crewProfile = nil
        profileError = nil
        profileLoading = false
    }

    private func loadProfile(login: String) async {
        let requestedPeriod = leaderboardPeriod
        do {
            let response: UserResp = try await get("/api/user", query: [
                URLQueryItem(name: "login", value: login),
                URLQueryItem(name: "period", value: requestedPeriod.rawValue)
            ])
            // Usage and status history are extras: a failure there must not
            // blank the profile, and an older backend simply doesn't have them.
            async let usageReq: VCUsageReport? = try? get("/api/usage", query: [
                URLQueryItem(name: "login", value: login),
                URLQueryItem(name: "period", value: requestedPeriod.rawValue)
            ]) as VCUsageReport
            async let historyReq: StatusHistoryResp? = try? get("/api/status/history", query: [
                URLQueryItem(name: "login", value: login),
                URLQueryItem(name: "limit", value: "8")
            ]) as StatusHistoryResp
            let (usage, history) = await (usageReq, historyReq)
            guard selectedProfileLogin == login, leaderboardPeriod == requestedPeriod else { return }
            crewProfile = VCCrewProfile(user: response.user,
                                        period: VCLeaderboardPeriod(rawValue: response.period ?? "") ?? requestedPeriod,
                                        devtimePeriod: response.devtimePeriod ?? response.devtimeToday,
                                        devtimeAll: response.devtimeAll ?? response.devtimeToday,
                                        online: response.online ?? false,
                                        sprints: response.sprints ?? [],
                                        periodStart: response.periodStart,
                                        periodEnd: response.periodEnd,
                                        daily: response.daily ?? [],
                                        activities: response.activities ?? [],
                                        usage: usage,
                                        recentStatuses: history?.sessions ?? [])
            profileLoading = false
        } catch {
            guard selectedProfileLogin == login, leaderboardPeriod == requestedPeriod else { return }
            profileError = vcFriendly(error)
            profileLoading = false
        }
    }

    // MARK: Refresh

    func selectLeaderboardPeriod(_ period: VCLeaderboardPeriod) {
        guard leaderboardPeriod != period else { return }
        leaderboardPeriod = period
        let profileLogin = selectedProfileLogin
        if profileLogin != nil { profileLoading = true }
        Task {
            await refreshLeaderboard()
            await refreshCrewUsage()
            if let profileLogin, selectedProfileLogin == profileLogin {
                await loadProfile(login: profileLogin)
            }
        }
    }

    func refresh() async {
        guard hasUsername else { return }
        errorText = nil
        do {
            let me: UserResp = try await get("/api/user", query: [URLQueryItem(name: "login", value: username)])
            user = me.user
            devtimeToday = me.devtimeToday
            updatePeriod(end: me.periodEnd, timezone: me.timezone)
            let onl: OnlineResp = try await get("/api/online")
            online = onl.online
            await refreshStatuses()
            await refreshLeaderboard()
            await refreshCrewUsage()
            lastRefresh = Date()
        } catch VCError.notFound {
            // fresh name, nothing recorded yet — fine
        } catch {
            errorText = vcFriendly(error)
        }
    }

    private func refreshLeaderboard() async {
        let requestedPeriod = leaderboardPeriod
        boardRefreshing = true
        do {
            let response: LeaderboardResp = try await get("/api/leaderboard", query: [
                URLQueryItem(name: "period", value: requestedPeriod.rawValue)
            ])
            guard leaderboardPeriod == requestedPeriod else { return }
            board = response.entries
            leaderboardPeriodStart = response.periodStart
            leaderboardPeriodEnd = response.periodEnd
            if let timezone = response.timezone, !timezone.isEmpty {
                leaderboardTimezone = timezone
            }
            boardRefreshing = false
            errorText = nil
        } catch {
            guard leaderboardPeriod == requestedPeriod else { return }
            boardRefreshing = false
            errorText = vcFriendly(error)
        }
    }

    /// Crew-wide app & site time for the selected period. Optional feed.
    private func refreshCrewUsage() async {
        let requestedPeriod = leaderboardPeriod
        guard let report: VCUsageReport = try? await get("/api/usage/crew", query: [
            URLQueryItem(name: "period", value: requestedPeriod.rawValue)
        ]) else { return }
        guard leaderboardPeriod == requestedPeriod else { return }
        if crewUsage != report { crewUsage = report }
    }

    // MARK: Profile photo

    /// Center-crop, downscale to 256 px, JPEG-encode locally, then upload.
    /// The original file never leaves the Mac.
    func uploadAvatar(from fileURL: URL) {
        guard hasUsername else { return }
        guard let image = NSImage(contentsOf: fileURL),
              let jpeg = Self.avatarJPEG(from: image) else {
            avatarError = "Couldn’t read that image"
            return
        }
        avatarBusy = true
        avatarError = nil
        let login = username
        Task {
            do {
                let body = try JSONEncoder().encode(AvatarUpload(user: login, image: jpeg.base64EncodedString()))
                let data = try await send("/api/avatar", method: "PUT", json: body)
                if let resp = try? snakeDecoder().decode(AvatarResp.self, from: data), var u = user {
                    u.avatarUrl = resp.avatarUrl
                    user = u
                }
                await refresh()
                if let shown = selectedProfileLogin { await loadProfile(login: shown) }
            } catch {
                avatarError = "Couldn’t upload photo: \(vcFriendly(error))"
            }
            avatarBusy = false
        }
    }

    func removeAvatar() {
        guard hasUsername else { return }
        avatarBusy = true
        avatarError = nil
        let login = username
        Task {
            do {
                let body = try JSONEncoder().encode(StatusClearRequest(user: login))
                _ = try await send("/api/avatar", method: "DELETE", json: body)
                if var u = user { u.avatarUrl = nil; user = u }
                await refresh()
            } catch {
                avatarError = "Couldn’t remove photo: \(vcFriendly(error))"
            }
            avatarBusy = false
        }
    }

    static func avatarJPEG(from image: NSImage, side: Int = 256) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        let s = min(w, h)
        guard s > 0, let square = cg.cropping(to: CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: App & site usage

    /// Upload whatever the tracker has gathered. Failed uploads go back into
    /// the tracker so the next minute retries them.
    func flushUsage(_ tracker: UsageTracker) {
        guard hasUsername, usageSharing else { _ = tracker.drain(); return }
        let usage = tracker.drain()
        guard !usage.isEmpty else { return }
        let login = username
        Task {
            do {
                let items = usage.sorted { $0.key < $1.key }.map { UsageUploadItem(key: $0.key, seconds: $0.value) }
                let body = try JSONEncoder().encode(UsageUpload(user: login, usage: items))
                _ = try await post("/api/usage", json: body)
            } catch {
                tracker.restore(usage)
            }
        }
    }

    // MARK: Status history (server-side)

    private var historySyncKey: String { "status.history.synced.v1.\(username)" }

    /// Upload completed statuses the server hasn't seen (or whose label
    /// changed), then pull back any the server has that this Mac doesn't —
    /// e.g. ones recorded on another machine. Idempotent: uploads upsert by id.
    func syncStatusHistory(_ store: StatusStore) {
        guard hasUsername else { return }
        let login = username
        let key = historySyncKey
        var synced = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let pending = store.history.filter { synced[$0.id.uuidString] != Self.signature($0) }
        Task {
            if !pending.isEmpty {
                for chunk in stride(from: 0, to: pending.count, by: 200).map({ Array(pending[$0..<min($0 + 200, pending.count)]) }) {
                    let payload = StatusHistoryUpload(user: login, sessions: chunk.compactMap { s in
                        guard let end = s.endedAt else { return nil }
                        return StatusHistoryItem(id: s.id.uuidString, emoji: s.emoji, message: s.message,
                                                 startedAt: s.startedAt, endedAt: end)
                    })
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    guard let body = try? encoder.encode(payload),
                          (try? await post("/api/status/history", json: body)) != nil else { return }
                    for s in chunk { synced[s.id.uuidString] = Self.signature(s) }
                    UserDefaults.standard.set(synced, forKey: key)
                }
            }
            if let remote: StatusHistoryResp = try? await get("/api/status/history", query: [
                URLQueryItem(name: "login", value: login),
                URLQueryItem(name: "limit", value: "500")
            ]) {
                let sessions = remote.sessions.compactMap { e -> StatusSession? in
                    guard let id = UUID(uuidString: e.id) else { return nil }
                    return StatusSession(id: id, emoji: e.emoji, message: e.message,
                                         startedAt: e.startedAt, endedAt: e.endedAt)
                }
                store.mergeRemote(sessions)
                for s in sessions { synced[s.id.uuidString] = synced[s.id.uuidString] ?? Self.signature(s) }
                UserDefaults.standard.set(synced, forKey: key)
            }
        }
    }

    private static func signature(_ s: StatusSession) -> String {
        "\(s.emoji)|\(s.message)|\(Int(s.startedAt.timeIntervalSince1970))|\(Int(s.endedAt?.timeIntervalSince1970 ?? 0))"
    }

    private func refreshStatuses() async {
        do {
            let response: StatusesResp = try await get("/api/statuses")
            crewStatuses = response.statuses
        } catch VCError.notFound {
            // Backward-compatible during a backend/app rollout.
            crewStatuses = []
        } catch {
            // Keep the rest of Crew usable if only this optional feed fails.
        }
    }

    // MARK: Shared statuses

    /// Queue status writes so a quick Start → Stop cannot arrive at the server
    /// out of order. This publishes the *active* value; completed sessions are
    /// stored server-side separately by `syncStatusHistory`.
    func publishStatus(_ session: StatusSession?) {
        guard hasUsername else {
            statusError = nil
            return
        }
        enqueueStatus(session, username: username, reportErrors: true)
    }

    private func enqueueStatus(_ session: StatusSession?, username: String, reportErrors: Bool) {
        statusSyncRevision += 1
        let revision = statusSyncRevision
        let previous = statusSyncTask
        statusSyncing = reportErrors
        statusSyncTask = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            do {
                if let session {
                    let payload = StatusWriteRequest(user: username,
                                                     emoji: session.emoji,
                                                     message: session.message,
                                                     startedAt: session.startedAt)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    _ = try await self.post("/api/status", json: encoder.encode(payload))
                } else {
                    let data = try JSONEncoder().encode(StatusClearRequest(user: username))
                    _ = try await self.send("/api/status", method: "DELETE", json: data)
                }
                if reportErrors { self.statusError = nil }
                await self.refreshStatuses()
            } catch {
                if reportErrors {
                    self.statusError = "Saved locally, but couldn’t share with Crew: \(vcFriendly(error))"
                }
            }
            if revision == self.statusSyncRevision {
                self.statusSyncing = false
            }
        }
    }

    // MARK: Devtime heartbeat

    /// Dev apps whose presence means "the user is coding". Mirrors the list in
    /// backend/client/devtime.sh.
    static let devAppNames = ["Cursor", "Code - Insiders", "Code", "iTerm2", "Terminal",
                              "Ghostty", "Warp", "WezTerm", "Alacritty", "kitty", "Neovide"]

    static func runningDevApp() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
        for name in devAppNames where running.contains(name) { return name }
        return nil
    }

    /// The user counts as present while the last keyboard/mouse/trackpad event
    /// is under this old. Past it, heartbeats stop and the backend's idle-gap
    /// rule closes the sprint — so a machine that is merely awake (DarkWake,
    /// walked away, overnight agents) stops accruing devtime.
    static let presenceCutoff: TimeInterval = 15 * 60

    /// Seconds since the last user input event. CGEventSource exposes only the
    /// elapsed-time counter — never which keys were pressed — and requires no
    /// Accessibility grant.
    static func secondsSinceLastInput() -> TimeInterval {
        let inputs: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved,
                                     .leftMouseDown, .rightMouseDown,
                                     .otherMouseDown, .scrollWheel]
        return inputs.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    /// Send a heartbeat while a dev app is running and the user is actually
    /// present; the backend accrues devtime and marks us online. Stays quiet
    /// on failure (background check).
    func heartbeatIfActive() {
        guard hasUsername, let app = Self.runningDevApp(),
              Self.secondsSinceLastInput() < Self.presenceCutoff else { return }
        Task {
            do {
                let body = try JSONEncoder().encode(["user": username, "app": app])
                let data = try await post("/api/pulse", json: body)
                let dec = snakeDecoder()
                if let resp = try? dec.decode(PulseResp.self, from: data) {
                    devtimeToday = resp.devtimeToday
                    updatePeriod(end: resp.periodEnd, timezone: resp.timezone)
                }
            } catch {
                // quiet: offline
            }
        }
    }

    // MARK: Networking

    private struct AvatarUpload: Encodable { var user: String; var image: String }
    private struct AvatarResp: Decodable {
        var avatarUrl: String?
        enum CodingKeys: String, CodingKey { case avatarUrl = "avatar_url" }
    }
    private struct UsageUploadItem: Encodable { var key: String; var seconds: Int }
    private struct UsageUpload: Encodable { var user: String; var usage: [UsageUploadItem] }
    private struct StatusHistoryItem: Encodable {
        var id: String
        var emoji: String
        var message: String
        var startedAt: Date
        var endedAt: Date
        enum CodingKeys: String, CodingKey {
            case id, emoji, message
            case startedAt = "started_at"
            case endedAt = "ended_at"
        }
    }
    private struct StatusHistoryUpload: Encodable { var user: String; var sessions: [StatusHistoryItem] }
    private struct StatusHistoryResp: Decodable { var sessions: [VCStatusEntry] }

    private struct UserResp: Decodable {
        var user: VCUser
        var devtimeToday: Int64
        var devtimeAll: Int64?
        var devtimePeriod: Int64?
        var period: String?
        var online: Bool?
        var sprints: [VCSprint]?
        var periodStart: Date?
        var periodEnd: Date?
        var timezone: String?
        var daily: [VCDay]?
        var activities: [VCActivityTotal]?
        enum CodingKeys: String, CodingKey {
            case user, online, period, sprints, timezone, daily, activities
            case devtimeToday = "devtime_today"
            case devtimeAll = "devtime_all"
            case devtimePeriod = "devtime_period"
            case periodStart = "period_start"
            case periodEnd = "period_end"
        }
    }
    private struct OnlineResp: Decodable { var online: [VCOnlineUser] }
    private struct StatusesResp: Decodable { var statuses: [VCCrewStatus] }
    private struct StatusWriteRequest: Encodable {
        var user: String
        var emoji: String
        var message: String
        var startedAt: Date
        enum CodingKeys: String, CodingKey {
            case user, emoji, message
            case startedAt = "started_at"
        }
    }
    private struct StatusClearRequest: Encodable { var user: String }
    private struct LeaderboardResp: Decodable {
        var entries: [VCLeaderboardEntry]
        var periodStart: Date?
        var periodEnd: Date?
        var timezone: String?
        enum CodingKeys: String, CodingKey {
            case entries, timezone
            case periodStart = "period_start"
            case periodEnd = "period_end"
        }
    }
    private struct PulseResp: Decodable {
        var devtimeToday: Int64
        var periodEnd: Date?
        var timezone: String?
        enum CodingKeys: String, CodingKey {
            case timezone
            case devtimeToday = "devtime_today"
            case periodEnd = "period_end"
        }
    }

    private func updatePeriod(end: Date?, timezone: String?) {
        if let end { todayPeriodEnd = end }
        if let timezone, !timezone.isEmpty { todayTimezone = timezone }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(url: Self.apiBaseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        if !query.isEmpty { comps.queryItems = query }
        let req = URLRequest(url: comps.url!)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw VCError.notFound }
        guard (200..<300).contains(status) else { throw VCError.failed("HTTP \(status)") }
        return try snakeDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, json: Data? = nil) async throws -> Data {
        try await send(path, method: "POST", json: json)
    }

    private func send(_ path: String, method: String, json: Data? = nil) async throws -> Data {
        var req = URLRequest(url: Self.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = json
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw VCError.failed("HTTP \(status)") }
        return data
    }
}

private func snakeDecoder() -> JSONDecoder {
    let dec = JSONDecoder()
    // No keyDecodingStrategy: explicit CodingKeys everywhere.
    dec.dateDecodingStrategy = .custom { d in
        let s = try d.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: s) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }
    return dec
}
