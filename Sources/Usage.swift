import AppKit
import Foundation

// MARK: - App & site usage
//
// Privacy model: the Mac decides what a moment of screen time *was* by
// matching the frontmost app (bundle id / name) or the active browser tab's
// host against a fixed catalog of major apps and sites. Anything not in the
// catalog is counted as `other`. Only catalog keys and seconds ever leave the
// machine — never app names, window titles, URLs, or hosts. The server keeps
// the same key set and folds anything else into `other` too.

struct UsageCatalogEntry {
    let key: String
    var bundleIDs: [String] = []        // exact bundle ids
    var bundlePrefixes: [String] = []   // e.g. "com.jetbrains."
    var appNamePrefixes: [String] = []  // for apps without a stable bundle id
    var domains: [String] = []          // host == d or host ends with ".d"
}

enum UsageCatalog {
    /// Keys must match the backend catalog (backend/catalog.go) exactly.
    static let entries: [UsageCatalogEntry] = [
        // Dev
        .init(key: "terminal", bundleIDs: ["com.apple.Terminal"]),
        .init(key: "iterm", bundleIDs: ["com.googlecode.iterm2"]),
        .init(key: "ghostty", bundleIDs: ["com.mitchellh.ghostty"]),
        .init(key: "warp", bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"]),
        .init(key: "wezterm", bundleIDs: ["com.github.wez.wezterm"]),
        .init(key: "alacritty", bundleIDs: ["org.alacritty", "io.alacritty"]),
        .init(key: "kitty", bundleIDs: ["net.kovidgoyal.kitty"]),
        .init(key: "cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], appNamePrefixes: ["Cursor"]),
        .init(key: "vscode", bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        .init(key: "xcode", bundleIDs: ["com.apple.dt.Xcode"]),
        .init(key: "zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        .init(key: "windsurf", bundleIDs: ["com.exafunction.windsurf"], appNamePrefixes: ["Windsurf"]),
        .init(key: "jetbrains", bundlePrefixes: ["com.jetbrains."], appNamePrefixes: ["Android Studio"]),
        .init(key: "sublime", bundlePrefixes: ["com.sublimetext."]),
        .init(key: "neovide", bundleIDs: ["com.neovide.neovide"], appNamePrefixes: ["Neovide"]),
        .init(key: "t3code", appNamePrefixes: ["T3 Code"], domains: ["t3.codes", "t3.chat"]),
        .init(key: "github", bundleIDs: ["com.github.GitHubClient"], domains: ["github.com", "githubusercontent.com"]),
        .init(key: "gitlab", domains: ["gitlab.com"]),
        .init(key: "stackoverflow", domains: ["stackoverflow.com", "stackexchange.com"]),
        .init(key: "docker", bundleIDs: ["com.docker.docker"], domains: ["docker.com"]),
        .init(key: "postman", bundleIDs: ["com.postmanlabs.mac"], domains: ["postman.com"]),
        .init(key: "tableplus", bundleIDs: ["com.tinyapp.TablePlus"]),
        .init(key: "vercel", domains: ["vercel.com"]),
        .init(key: "render", domains: ["render.com", "dashboard.render.com"]),
        .init(key: "aws", domains: ["aws.amazon.com", "console.aws.amazon.com", "awsapps.com"]),
        .init(key: "gcp", domains: ["console.cloud.google.com", "cloud.google.com"]),
        .init(key: "cloudflare", domains: ["cloudflare.com"]),
        .init(key: "supabase", domains: ["supabase.com"]),
        .init(key: "sentry", domains: ["sentry.io"]),
        .init(key: "datadog", domains: ["datadoghq.com"]),
        .init(key: "linear", bundleIDs: ["com.linear"], domains: ["linear.app"]),
        .init(key: "jira", domains: ["atlassian.net", "atlassian.com"]),
        .init(key: "railway", domains: ["railway.app", "railway.com"]),
        .init(key: "netlify", domains: ["netlify.com", "app.netlify.com"]),
        .init(key: "npm", domains: ["npmjs.com"]),
        // AI
        .init(key: "claude", bundleIDs: ["com.anthropic.claudefordesktop"], domains: ["claude.ai"]),
        .init(key: "chatgpt", bundleIDs: ["com.openai.chat"], domains: ["chatgpt.com", "chat.openai.com"]),
        .init(key: "gemini", domains: ["gemini.google.com", "aistudio.google.com"]),
        .init(key: "perplexity", bundleIDs: ["ai.perplexity.mac"], domains: ["perplexity.ai"]),
        .init(key: "grok", domains: ["grok.com"]),
        .init(key: "codex", bundleIDs: ["com.openai.codex"], domains: ["chatgpt.com/codex"]),
        // Crew sites
        .init(key: "kairos", domains: ["kairos.trade"]),
        .init(key: "ionicfi", domains: ["ionicfi.com"]),
        .init(key: "intellipickz", domains: ["intellipickz.com"]),
        .init(key: "rivyl", domains: ["rivyl.xyz"]),
        .init(key: "goathud", domains: ["goathud.com"]),
        // Communication
        .init(key: "slack", bundleIDs: ["com.tinyspeck.slackmacgap"], domains: ["slack.com"]),
        .init(key: "discord", bundleIDs: ["com.hnc.Discord"], domains: ["discord.com"]),
        .init(key: "zoom", bundleIDs: ["us.zoom.xos"], domains: ["zoom.us"]),
        .init(key: "teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"], domains: ["teams.microsoft.com"]),
        .init(key: "telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"], domains: ["web.telegram.org"]),
        .init(key: "whatsapp", bundleIDs: ["net.whatsapp.WhatsApp"], domains: ["web.whatsapp.com"]),
        .init(key: "messages", bundleIDs: ["com.apple.MobileSMS"]),
        .init(key: "mail", bundleIDs: ["com.apple.mail"]),
        .init(key: "gmail", domains: ["mail.google.com"]),
        .init(key: "outlook", bundleIDs: ["com.microsoft.Outlook"], domains: ["outlook.live.com", "outlook.office.com"]),
        .init(key: "meet", domains: ["meet.google.com"]),
        .init(key: "calendar", bundleIDs: ["com.apple.iCal"], domains: ["calendar.google.com"]),
        .init(key: "superhuman", bundleIDs: ["com.superhuman.electron"], domains: ["mail.superhuman.com"]),
        .init(key: "facetime", bundleIDs: ["com.apple.FaceTime"]),
        // Productivity
        .init(key: "notion", bundleIDs: ["notion.id"], domains: ["notion.so", "notion.site"]),
        .init(key: "figma", bundleIDs: ["com.figma.Desktop"], domains: ["figma.com"]),
        .init(key: "googledocs", domains: ["docs.google.com"]),
        .init(key: "googledrive", domains: ["drive.google.com"]),
        .init(key: "notes", bundleIDs: ["com.apple.Notes"]),
        .init(key: "obsidian", bundleIDs: ["md.obsidian"]),
        .init(key: "excel", bundleIDs: ["com.microsoft.Excel"]),
        .init(key: "word", bundleIDs: ["com.microsoft.Word"]),
        .init(key: "powerpoint", bundleIDs: ["com.microsoft.Powerpoint"]),
        .init(key: "keynote", bundleIDs: ["com.apple.iWork.Keynote"]),
        .init(key: "pages", bundleIDs: ["com.apple.iWork.Pages"]),
        .init(key: "numbers", bundleIDs: ["com.apple.iWork.Numbers"]),
        .init(key: "finder", bundleIDs: ["com.apple.finder"]),
        .init(key: "preview", bundleIDs: ["com.apple.Preview"]),
        .init(key: "raycast", bundleIDs: ["com.raycast.macos"]),
        .init(key: "things", bundleIDs: ["com.culturedcode.ThingsMac"]),
        .init(key: "todoist", bundleIDs: ["com.todoist.mac.Todoist"], domains: ["todoist.com"]),
        .init(key: "airtable", domains: ["airtable.com"]),
        .init(key: "miro", bundleIDs: ["com.electron.realtimeboard"], domains: ["miro.com"]),
        .init(key: "loom", bundleIDs: ["com.loom.desktop"], domains: ["loom.com"]),
        .init(key: "canva", bundleIDs: ["com.canva.CanvaDesktop"], domains: ["canva.com"]),
        // Social
        .init(key: "x", domains: ["x.com", "twitter.com"]),
        .init(key: "reddit", domains: ["reddit.com"]),
        .init(key: "instagram", domains: ["instagram.com"]),
        .init(key: "facebook", domains: ["facebook.com", "messenger.com"]),
        .init(key: "linkedin", domains: ["linkedin.com"]),
        .init(key: "tiktok", domains: ["tiktok.com"]),
        .init(key: "threads", domains: ["threads.net", "threads.com"]),
        .init(key: "bluesky", domains: ["bsky.app"]),
        .init(key: "hackernews", domains: ["news.ycombinator.com"]),
        .init(key: "producthunt", domains: ["producthunt.com"]),
        // Video
        .init(key: "youtube", domains: ["youtube.com", "youtu.be"]),
        .init(key: "netflix", domains: ["netflix.com"]),
        .init(key: "twitch", domains: ["twitch.tv"]),
        .init(key: "hulu", domains: ["hulu.com"]),
        .init(key: "disneyplus", domains: ["disneyplus.com"]),
        .init(key: "max", domains: ["max.com", "hbomax.com"]),
        .init(key: "primevideo", domains: ["primevideo.com"]),
        .init(key: "crunchyroll", domains: ["crunchyroll.com"]),
        .init(key: "vlc", bundleIDs: ["org.videolan.vlc"]),
        .init(key: "iina", bundleIDs: ["com.colliderli.iina"]),
        .init(key: "quicktime", bundleIDs: ["com.apple.QuickTimePlayerX"]),
        // Music
        .init(key: "spotify", bundleIDs: ["com.spotify.client"], domains: ["open.spotify.com"]),
        .init(key: "applemusic", bundleIDs: ["com.apple.Music"], domains: ["music.apple.com"]),
        .init(key: "soundcloud", domains: ["soundcloud.com"]),
        .init(key: "podcasts", bundleIDs: ["com.apple.podcasts"]),
        // Finance
        .init(key: "tradingview", bundleIDs: ["com.tradingview.tradingviewapp.desktop"], domains: ["tradingview.com"]),
        .init(key: "hyperliquid", domains: ["hyperliquid.xyz"]),
        .init(key: "coinbase", domains: ["coinbase.com"]),
        .init(key: "binance", domains: ["binance.com", "binance.us"]),
        .init(key: "robinhood", domains: ["robinhood.com"]),
        .init(key: "polymarket", domains: ["polymarket.com"]),
        .init(key: "kalshi", domains: ["kalshi.com"]),
        .init(key: "dexscreener", domains: ["dexscreener.com"]),
        .init(key: "phantom", domains: ["phantom.app", "phantom.com"]),
        // Shopping
        .init(key: "amazon", domains: ["amazon.com"]),
        .init(key: "ebay", domains: ["ebay.com"]),
        // News
        .init(key: "nytimes", domains: ["nytimes.com"]),
        .init(key: "wsj", domains: ["wsj.com"]),
        .init(key: "bloomberg", domains: ["bloomberg.com"]),
        // Games
        .init(key: "steam", bundleIDs: ["com.valvesoftware.steam"], domains: ["store.steampowered.com", "steamcommunity.com"]),
        .init(key: "chess", domains: ["chess.com"]),
    ]

    static let other = "other"

    /// Browsers whose active tab we can read with AppleScript, and the snippet
    /// that returns the tab's URL. Firefox has no such API; its time counts as
    /// `other` unless the page is identified some other way.
    static let browsers: [String: String] = {
        let chromium = "get URL of active tab of front window"
        var m: [String: String] = [
            "com.apple.Safari": "get URL of front document",
            "com.apple.SafariTechnologyPreview": "get URL of front document",
        ]
        for id in ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
                   "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
                   "company.thebrowser.Browser", "company.thebrowser.dia",
                   "com.operasoftware.Opera", "ai.perplexity.comet"] {
            m[id] = chromium
        }
        return m
    }()

    static func key(bundleID: String?, appName: String?) -> String? {
        let bid = bundleID ?? ""
        let name = appName ?? ""
        for e in entries {
            if !bid.isEmpty {
                if e.bundleIDs.contains(bid) { return e.key }
                if e.bundlePrefixes.contains(where: { bid.hasPrefix($0) }) { return e.key }
            }
            if !name.isEmpty, e.appNamePrefixes.contains(where: { name.hasPrefix($0) }) { return e.key }
        }
        return nil
    }

    /// Match a page URL. Only the host (plus a path prefix for the few
    /// catalog entries that need one, like chatgpt.com/codex) is consulted.
    static func key(url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path.lowercased()
        var best: (key: String, len: Int)?
        for e in entries {
            for d in e.domains {
                var domain = d
                var pathPrefix = ""
                if let slash = d.firstIndex(of: "/") {
                    domain = String(d[..<slash])
                    pathPrefix = String(d[slash...])
                }
                guard h == domain || h.hasSuffix("." + domain) else { continue }
                if !pathPrefix.isEmpty && !path.hasPrefix(pathPrefix) { continue }
                // Most specific wins: chatgpt.com/codex beats chatgpt.com,
                // mail.google.com beats google.com.
                let len = d.count
                if best == nil || len > best!.len { best = (e.key, len) }
            }
        }
        return best?.key
    }
}

/// Samples what's on screen every few seconds and accumulates seconds per
/// catalog key until the next flush.
@MainActor
final class UsageTracker {
    static let enabledKey = "usage.sharingEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Seconds between samples. Each sample credits this much time.
    static let sampleInterval: TimeInterval = 5
    /// Idle longer than this and nothing is counted — the screen is on, nobody's there.
    static let idleCutoff: TimeInterval = 120

    private(set) var pending: [String: Int] = [:]
    private var timer: Timer?
    private var scripts: [String: NSAppleScript] = [:]
    private var lastSample = Date()

    func start() {
        timer?.invalidate()
        lastSample = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            guard let tracker = self else { return }
            Task { @MainActor in tracker.sample() }
        }
    }

    private func sample() {
        let now = Date()
        // Credit real elapsed time, but never more than two intervals: a
        // sleeping Mac must not wake up and claim the whole night.
        let elapsed = min(now.timeIntervalSince(lastSample), Self.sampleInterval * 2)
        lastSample = now
        guard Self.isEnabled, elapsed > 0,
              VibecodersStore.secondsSinceLastInput() < Self.idleCutoff,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let key = classify(app)
        pending[key, default: 0] += Int(elapsed.rounded())
        // Don't hoard: if the network has been down for ages, keep at most ~15 min.
        if pending.values.reduce(0, +) > 900 {
            pending = pending.mapValues { $0 * 900 / max(1, pending.values.reduce(0, +)) }
        }
    }

    private func classify(_ app: NSRunningApplication) -> String {
        let bid = app.bundleIdentifier
        if let bid, let snippet = UsageCatalog.browsers[bid] {
            if let raw = activeTabURL(bundleID: bid, snippet: snippet),
               let url = URL(string: raw), let key = UsageCatalog.key(url: url) {
                return key
            }
            return UsageCatalog.other
        }
        return UsageCatalog.key(bundleID: bid, appName: app.localizedName) ?? UsageCatalog.other
    }

    /// The active tab's URL, read through AppleScript. The URL is matched and
    /// dropped immediately; it is never stored or sent.
    private func activeTabURL(bundleID: String, snippet: String) -> String? {
        let script: NSAppleScript
        if let cached = scripts[bundleID] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: "tell application id \"\(bundleID)\" to \(snippet)") else { return nil }
            scripts[bundleID] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }

    /// Hand over everything accumulated so far and reset.
    func drain() -> [String: Int] {
        let out = pending.filter { $0.value > 0 }
        pending = [:]
        return out
    }

    /// Put time back after a failed upload so it goes out with the next flush.
    func restore(_ usage: [String: Int]) {
        for (k, v) in usage { pending[k, default: 0] += v }
    }
}
