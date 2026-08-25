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

    enum CodingKeys: String, CodingKey {
        case id, login, name
        case lastSeen = "last_seen"
        case createdAt = "created_at"
    }
}

struct VCCrewProfile: Equatable {
    var user: VCUser
    var devtimeToday: Int64
    var devtimeAll: Int64
    var online: Bool
}

struct VCOnlineUser: Codable, Equatable {
    var login: String
    var name: String?
    var lastSeen: Date?
    var devtimeToday: Int64

    enum CodingKeys: String, CodingKey {
        case login, name
        case lastSeen = "last_seen"
        case devtimeToday = "devtime_today"
    }
}

struct VCLeaderboardEntry: Codable, Equatable {
    var rank: Int
    var login: String
    var name: String?
    var value: Int64
    var online: Bool
    var lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case rank, login, name, value, online
        case lastSeen = "last_seen"
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

// MARK: - Store

@MainActor
final class VibecodersStore: NSObject, ObservableObject {
    static let apiBaseURL = URL(string: "https://greptile-hud.onrender.com")!

    @Published private(set) var user: VCUser?
    @Published private(set) var online: [VCOnlineUser] = []
    @Published private(set) var board: [VCLeaderboardEntry] = []
    @Published private(set) var devtimeToday: Int64 = 0
    @Published private(set) var todayPeriodEnd: Date?
    @Published private(set) var todayTimezone = "UTC"
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var selectedProfileLogin: String?
    @Published private(set) var crewProfile: VCCrewProfile?
    @Published private(set) var profileLoading = false
    @Published private(set) var profileError: String?
    @Published var errorText: String?

    private static let usernameKey = "vibecoders.username"

    var username: String { UserDefaults.standard.string(forKey: Self.usernameKey) ?? "" }
    var hasUsername: Bool { !username.isEmpty }
    var todayPeriodDescription: String {
        guard let end = todayPeriodEnd else { return "Today is measured in UTC." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Today is measured in \(todayTimezone) and resets at \(formatter.string(from: end)) in your local time."
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
        UserDefaults.standard.set(cleaned, forKey: Self.usernameKey)
        user = nil
        online = []
        board = []
        devtimeToday = 0
        todayPeriodEnd = nil
        dismissProfile()
        errorText = nil
        Task { await refresh() }
    }

    func clearUsername() {
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        user = nil
        online = []
        board = []
        devtimeToday = 0
        todayPeriodEnd = nil
        dismissProfile()
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
        do {
            let response: UserResp = try await get("/api/user", query: [URLQueryItem(name: "login", value: login)])
            guard selectedProfileLogin == login else { return }
            crewProfile = VCCrewProfile(user: response.user,
                                        devtimeToday: response.devtimeToday,
                                        devtimeAll: response.devtimeAll ?? response.devtimeToday,
                                        online: response.online ?? false)
            profileLoading = false
        } catch {
            guard selectedProfileLogin == login else { return }
            profileError = vcFriendly(error)
            profileLoading = false
        }
    }

    // MARK: Refresh

    func refresh() async {
        guard hasUsername else { return }
        do {
            let me: UserResp = try await get("/api/user", query: [URLQueryItem(name: "login", value: username)])
            user = me.user
            devtimeToday = me.devtimeToday
            updatePeriod(end: me.periodEnd, timezone: me.timezone)
            let onl: OnlineResp = try await get("/api/online")
            online = onl.online
            let lb: LeaderboardResp = try await get("/api/leaderboard",
                                                    query: [URLQueryItem(name: "period", value: "today")])
            board = lb.entries
            updatePeriod(end: lb.periodEnd, timezone: lb.timezone)
            lastRefresh = Date()
            errorText = nil
        } catch VCError.notFound {
            // fresh name, nothing recorded yet — fine
        } catch {
            errorText = vcFriendly(error)
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

    /// Send a heartbeat while a dev app is running; the backend accrues devtime
    /// and marks us online. Stays quiet on failure (background check).
    func heartbeatIfActive() {
        guard hasUsername, let app = Self.runningDevApp() else { return }
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

    private struct UserResp: Decodable {
        var user: VCUser
        var devtimeToday: Int64
        var devtimeAll: Int64?
        var online: Bool?
        var periodEnd: Date?
        var timezone: String?
        enum CodingKeys: String, CodingKey {
            case user, online, timezone
            case devtimeToday = "devtime_today"
            case devtimeAll = "devtime_all"
            case periodEnd = "period_end"
        }
    }
    private struct OnlineResp: Decodable { var online: [VCOnlineUser] }
    private struct LeaderboardResp: Decodable {
        var entries: [VCLeaderboardEntry]
        var periodEnd: Date?
        var timezone: String?
        enum CodingKeys: String, CodingKey {
            case entries, timezone
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
        var req = URLRequest(url: Self.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
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
