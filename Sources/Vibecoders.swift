import AppKit
import AuthenticationServices
import Combine
import Foundation

// MARK: - API shapes (backend: greptilehud/backend, see backend/README.md)

struct VCUser: Codable, Equatable {
    var id: Int64
    var githubId: Int64
    var login: String
    var name: String?
    var avatarUrl: String?
    var orgs: [String]
    var lastSeen: Date?
    var lastSyncAt: Date?
}

struct VCStats: Codable, Equatable {
    var commits30d: Int64 = 0
    var commitsAll: Int64 = 0
    var loc30d: Int64 = 0
    var locAll: Int64 = 0
    var prs30d: Int64 = 0
    var prsAll: Int64 = 0
}

struct VCOnlineUser: Codable, Equatable {
    var login: String
    var name: String?
    var avatarUrl: String?
    var lastSeen: Date?
    var devtimeToday: Int64
}

struct VCLeaderboardEntry: Codable, Equatable {
    var rank: Int
    var login: String
    var name: String?
    var avatarUrl: String?
    var value: Int64
    var online: Bool
    var lastSeen: Date?
}

enum VCMetric: String, CaseIterable {
    case devtime, commits, loc, prs

    var label: String {
        switch self {
        case .devtime: return "Devtime"
        case .commits: return "Commits"
        case .loc: return "Lines"
        case .prs: return "PRs"
        }
    }

    func format(_ value: Int64) -> String {
        switch self {
        case .devtime: return vcDuration(value)
        default: return vcCount(value)
        }
    }
}

enum VCError: Error {
    case unauthorized
    case failed(String)
}

func vcFriendly(_ error: Error) -> String {
    if let e = error as? VCError {
        switch e {
        case .unauthorized: return "Not signed in anymore"
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

func vcCount(_ n: Int64) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

// MARK: - Store

@MainActor
final class VibecodersStore: ObservableObject {
    static let apiBaseURL = URL(string: "https://greptile-hud.onrender.com")!
    static let callbackScheme = "greptilehud"

    @Published private(set) var user: VCUser?
    @Published private(set) var stats = VCStats()
    @Published private(set) var online: [VCOnlineUser] = []
    @Published private(set) var boards: [VCMetric: [VCLeaderboardEntry]] = [:]
    @Published var selectedMetric: VCMetric = .devtime
    @Published private(set) var devtimeToday: Int64 = 0
    @Published private(set) var syncing = false
    @Published private(set) var lastRefresh: Date?
    @Published var errorText: String?

    private var session: ASWebAuthenticationSession?

    private static let tokenKey = "vibecoders.token"
    private static let loginKey = "vibecoders.login"

    var isSignedIn: Bool { user != nil }

    var login: String { user?.login ?? UserDefaults.standard.string(forKey: Self.loginKey) ?? "" }

    private var token: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenKey) }
    }

    func leaderboard(for metric: VCMetric) -> [VCLeaderboardEntry] {
        boards[metric] ?? []
    }

    // MARK: Auth

    func signIn() {
        guard session == nil else { return }
        let url = Self.apiBaseURL.appendingPathComponent("auth/login")
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                self.session = nil
                if let error {
                    let nserr = error as NSError
                    if nserr.code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        self.errorText = "Sign-in failed: \(error.localizedDescription)"
                    }
                    return
                }
                if let url { self.completeOAuth(url: url) }
            }
        }
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        _ = session.start()
    }

    /// Handles `greptilehud://oauth/callback?token=…&login=…` (also used for
    /// deep links arriving via application(_:open:) if the OAuth window was
    /// dismissed first).
    func completeOAuth(url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let token = comps?.queryItems?.first { $0.name == "token" }?.value
        let login = comps?.queryItems?.first { $0.name == "login" }?.value
        guard let token, !token.isEmpty else {
            errorText = "Sign-in returned no token"
            return
        }
        self.token = token
        if let login { UserDefaults.standard.set(login, forKey: Self.loginKey) }
        errorText = nil
        Task { await refresh() }
    }

    func signOut() {
        let t = token
        token = nil
        UserDefaults.standard.removeObject(forKey: Self.loginKey)
        user = nil
        online = []
        boards = [:]
        devtimeToday = 0
        syncing = false
        errorText = nil
        if let t {
            Task { _ = try? await Self.revokeToken(t) }
        }
    }

    // MARK: Refresh

    func refresh() async {
        guard token != nil else { return }
        do {
            let me: MeResp = try await get("/api/me")
            user = me.user
            stats = me.stats
            devtimeToday = me.devtimeToday
            let onl: OnlineResp = try await get("/api/online")
            online = onl.online
            for m in VCMetric.allCases {
                let lb: LeaderboardResp = try await get("/api/leaderboard",
                                                        query: [URLQueryItem(name: "metric", value: m.rawValue),
                                                                URLQueryItem(name: "period", value: "30d")])
                boards[m] = lb.entries
            }
            lastRefresh = Date()
            errorText = nil
        } catch VCError.unauthorized {
            signOut()
        } catch {
            errorText = vcFriendly(error)
        }
    }

    func syncNow() {
        guard token != nil else { return }
        syncing = true
        Task {
            defer { syncing = false }
            do {
                _ = try await post("/api/sync")
            } catch {
                errorText = vcFriendly(error)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh()
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
        guard token != nil, let app = Self.runningDevApp() else { return }
        Task {
            do {
                let body = try JSONEncoder().encode(["app": app])
                let data = try await post("/api/pulse", json: body)
                let dec = snakeDecoder()
                if let resp = try? dec.decode(PulseResp.self, from: data) {
                    devtimeToday = resp.devtimeToday
                }
            } catch {
                // quiet: offline or not signed in
            }
        }
    }

    // MARK: Networking

    private struct MeResp: Decodable { var user: VCUser; var stats: VCStats; var devtimeToday: Int64 }
    private struct OnlineResp: Decodable { var online: [VCOnlineUser] }
    private struct LeaderboardResp: Decodable { var entries: [VCLeaderboardEntry] }
    private struct PulseResp: Decodable { var devtimeToday: Int64 }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(url: Self.apiBaseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw VCError.unauthorized }
        guard (200..<300).contains(status) else { throw VCError.failed("HTTP \(status)") }
        return try snakeDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, json: Data? = nil) async throws -> Data {
        var req = URLRequest(url: Self.apiBaseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = json
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw VCError.unauthorized }
        guard (200..<300).contains(status) else { throw VCError.failed("HTTP \(status)") }
        return data
    }

    private static func revokeToken(_ token: String) async throws {
        var req = URLRequest(url: apiBaseURL.appendingPathComponent("api/tokens/\(token)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: req)
    }
}

private func snakeDecoder() -> JSONDecoder {
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
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
