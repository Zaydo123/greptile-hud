package main

// The app/site usage catalog. The Mac app maps the frontmost app or the active
// browser tab's host to one of these keys locally and sends only the key, so
// private app names and URLs never leave the machine. The server keeps the
// exact same set and folds anything it doesn't recognise into "other" (defence
// in depth against an old or misbehaving client). This list is part of the
// API contract with the macOS client: adding, renaming or removing a key must
// be done on both sides together.

type catalogEntry struct {
	Key      string
	Label    string
	Category string
}

// usageOtherKey is where every unknown key is folded. It is itself a catalog
// entry (label "Other", category "Other") so it renders like any other item.
const usageOtherKey = "other"

// usageCatalog is ordered as the contract lists it. Order is informational
// only; responses sort by seconds, not by catalog position.
var usageCatalog = []catalogEntry{
	// Dev
	{Key: "terminal", Label: "Terminal", Category: "Dev"},
	{Key: "iterm", Label: "iTerm2", Category: "Dev"},
	{Key: "ghostty", Label: "Ghostty", Category: "Dev"},
	{Key: "warp", Label: "Warp", Category: "Dev"},
	{Key: "wezterm", Label: "WezTerm", Category: "Dev"},
	{Key: "alacritty", Label: "Alacritty", Category: "Dev"},
	{Key: "kitty", Label: "kitty", Category: "Dev"},
	{Key: "cursor", Label: "Cursor", Category: "Dev"},
	{Key: "vscode", Label: "VS Code", Category: "Dev"},
	{Key: "xcode", Label: "Xcode", Category: "Dev"},
	{Key: "zed", Label: "Zed", Category: "Dev"},
	{Key: "windsurf", Label: "Windsurf", Category: "Dev"},
	{Key: "jetbrains", Label: "JetBrains IDEs", Category: "Dev"},
	{Key: "sublime", Label: "Sublime Text", Category: "Dev"},
	{Key: "neovide", Label: "Neovide", Category: "Dev"},
	{Key: "t3code", Label: "T3 Code", Category: "Dev"},
	{Key: "github", Label: "GitHub", Category: "Dev"},
	{Key: "gitlab", Label: "GitLab", Category: "Dev"},
	{Key: "stackoverflow", Label: "Stack Overflow", Category: "Dev"},
	{Key: "docker", Label: "Docker", Category: "Dev"},
	{Key: "postman", Label: "Postman", Category: "Dev"},
	{Key: "tableplus", Label: "TablePlus", Category: "Dev"},
	{Key: "vercel", Label: "Vercel", Category: "Dev"},
	{Key: "render", Label: "Render", Category: "Dev"},
	{Key: "aws", Label: "AWS", Category: "Dev"},
	{Key: "gcp", Label: "Google Cloud", Category: "Dev"},
	{Key: "cloudflare", Label: "Cloudflare", Category: "Dev"},
	{Key: "supabase", Label: "Supabase", Category: "Dev"},
	{Key: "sentry", Label: "Sentry", Category: "Dev"},
	{Key: "datadog", Label: "Datadog", Category: "Dev"},
	{Key: "linear", Label: "Linear", Category: "Dev"},
	{Key: "jira", Label: "Jira", Category: "Dev"},
	{Key: "railway", Label: "Railway", Category: "Dev"},
	{Key: "netlify", Label: "Netlify", Category: "Dev"},
	{Key: "npm", Label: "npm", Category: "Dev"},

	// AI
	{Key: "claude", Label: "Claude", Category: "AI"},
	{Key: "chatgpt", Label: "ChatGPT", Category: "AI"},
	{Key: "gemini", Label: "Gemini", Category: "AI"},
	{Key: "perplexity", Label: "Perplexity", Category: "AI"},
	{Key: "grok", Label: "Grok", Category: "AI"},
	{Key: "codex", Label: "Codex", Category: "AI"},

	// Crew
	{Key: "kairos", Label: "Kairos", Category: "Crew"},
	{Key: "ionicfi", Label: "IonicFi", Category: "Crew"},
	{Key: "intellipickz", Label: "IntelliPickz", Category: "Crew"},
	{Key: "rivyl", Label: "Rivyl", Category: "Crew"},
	{Key: "goathud", Label: "GOAT HUD", Category: "Crew"},

	// Communication
	{Key: "slack", Label: "Slack", Category: "Communication"},
	{Key: "discord", Label: "Discord", Category: "Communication"},
	{Key: "zoom", Label: "Zoom", Category: "Communication"},
	{Key: "teams", Label: "Microsoft Teams", Category: "Communication"},
	{Key: "telegram", Label: "Telegram", Category: "Communication"},
	{Key: "whatsapp", Label: "WhatsApp", Category: "Communication"},
	{Key: "messages", Label: "Messages", Category: "Communication"},
	{Key: "mail", Label: "Mail", Category: "Communication"},
	{Key: "gmail", Label: "Gmail", Category: "Communication"},
	{Key: "outlook", Label: "Outlook", Category: "Communication"},
	{Key: "meet", Label: "Google Meet", Category: "Communication"},
	{Key: "calendar", Label: "Calendar", Category: "Communication"},
	{Key: "superhuman", Label: "Superhuman", Category: "Communication"},
	{Key: "facetime", Label: "FaceTime", Category: "Communication"},

	// Productivity
	{Key: "notion", Label: "Notion", Category: "Productivity"},
	{Key: "figma", Label: "Figma", Category: "Productivity"},
	{Key: "googledocs", Label: "Google Docs", Category: "Productivity"},
	{Key: "googledrive", Label: "Google Drive", Category: "Productivity"},
	{Key: "notes", Label: "Notes", Category: "Productivity"},
	{Key: "obsidian", Label: "Obsidian", Category: "Productivity"},
	{Key: "excel", Label: "Excel", Category: "Productivity"},
	{Key: "word", Label: "Word", Category: "Productivity"},
	{Key: "powerpoint", Label: "PowerPoint", Category: "Productivity"},
	{Key: "keynote", Label: "Keynote", Category: "Productivity"},
	{Key: "pages", Label: "Pages", Category: "Productivity"},
	{Key: "numbers", Label: "Numbers", Category: "Productivity"},
	{Key: "finder", Label: "Finder", Category: "Productivity"},
	{Key: "preview", Label: "Preview", Category: "Productivity"},
	{Key: "raycast", Label: "Raycast", Category: "Productivity"},
	{Key: "things", Label: "Things", Category: "Productivity"},
	{Key: "todoist", Label: "Todoist", Category: "Productivity"},
	{Key: "airtable", Label: "Airtable", Category: "Productivity"},
	{Key: "miro", Label: "Miro", Category: "Productivity"},
	{Key: "loom", Label: "Loom", Category: "Productivity"},
	{Key: "canva", Label: "Canva", Category: "Productivity"},

	// Social
	{Key: "x", Label: "X", Category: "Social"},
	{Key: "reddit", Label: "Reddit", Category: "Social"},
	{Key: "instagram", Label: "Instagram", Category: "Social"},
	{Key: "facebook", Label: "Facebook", Category: "Social"},
	{Key: "linkedin", Label: "LinkedIn", Category: "Social"},
	{Key: "tiktok", Label: "TikTok", Category: "Social"},
	{Key: "threads", Label: "Threads", Category: "Social"},
	{Key: "bluesky", Label: "Bluesky", Category: "Social"},
	{Key: "hackernews", Label: "Hacker News", Category: "Social"},
	{Key: "producthunt", Label: "Product Hunt", Category: "Social"},

	// Video
	{Key: "youtube", Label: "YouTube", Category: "Video"},
	{Key: "netflix", Label: "Netflix", Category: "Video"},
	{Key: "twitch", Label: "Twitch", Category: "Video"},
	{Key: "hulu", Label: "Hulu", Category: "Video"},
	{Key: "disneyplus", Label: "Disney+", Category: "Video"},
	{Key: "max", Label: "Max", Category: "Video"},
	{Key: "primevideo", Label: "Prime Video", Category: "Video"},
	{Key: "crunchyroll", Label: "Crunchyroll", Category: "Video"},
	{Key: "vlc", Label: "VLC", Category: "Video"},
	{Key: "iina", Label: "IINA", Category: "Video"},
	{Key: "quicktime", Label: "QuickTime", Category: "Video"},

	// Music
	{Key: "spotify", Label: "Spotify", Category: "Music"},
	{Key: "applemusic", Label: "Apple Music", Category: "Music"},
	{Key: "soundcloud", Label: "SoundCloud", Category: "Music"},
	{Key: "podcasts", Label: "Podcasts", Category: "Music"},

	// Finance
	{Key: "tradingview", Label: "TradingView", Category: "Finance"},
	{Key: "hyperliquid", Label: "Hyperliquid", Category: "Finance"},
	{Key: "coinbase", Label: "Coinbase", Category: "Finance"},
	{Key: "binance", Label: "Binance", Category: "Finance"},
	{Key: "robinhood", Label: "Robinhood", Category: "Finance"},
	{Key: "polymarket", Label: "Polymarket", Category: "Finance"},
	{Key: "kalshi", Label: "Kalshi", Category: "Finance"},
	{Key: "dexscreener", Label: "DEX Screener", Category: "Finance"},
	{Key: "phantom", Label: "Phantom", Category: "Finance"},

	// Shopping
	{Key: "amazon", Label: "Amazon", Category: "Shopping"},
	{Key: "ebay", Label: "eBay", Category: "Shopping"},

	// News
	{Key: "nytimes", Label: "New York Times", Category: "News"},
	{Key: "wsj", Label: "Wall Street Journal", Category: "News"},
	{Key: "bloomberg", Label: "Bloomberg", Category: "News"},

	// Games
	{Key: "steam", Label: "Steam", Category: "Games"},
	{Key: "chess", Label: "Chess.com", Category: "Games"},

	// Other
	{Key: "other", Label: "Other", Category: "Other"}}

// usageCatalogByKey is the lookup view of usageCatalog.
var usageCatalogByKey = func() map[string]catalogEntry {
	m := make(map[string]catalogEntry, len(usageCatalog))
	for _, e := range usageCatalog {
		m[e.Key] = e
	}
	return m
}()

// catalogKey returns key when it is in the catalog and "other" otherwise. Keys
// are matched exactly: the client sends lowercase catalog keys, and anything
// else is by definition not one of them.
func catalogKey(key string) string {
	if _, ok := usageCatalogByKey[key]; ok {
		return key
	}
	return usageOtherKey
}

// catalogLookup returns the entry for key, folding unknown keys into "other".
func catalogLookup(key string) catalogEntry {
	return usageCatalogByKey[catalogKey(key)]
}
