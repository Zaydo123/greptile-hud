import SwiftUI

/// Tokyo Night palette — the whole HUD draws from here, so a re-tint is a
/// one-file change. Values are the canonical `tokyonight` (night variant)
/// hexes; the "bebop" extras are the warm accents the theme leaves open.
enum Tokyo {
    private static func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255,
              opacity: alpha)
    }

    // Surfaces
    static let bg = hex(0x1A1B26)          // editor background
    static let bgDark = hex(0x16161E)      // sidebar / deeper panes
    static let bgHighlight = hex(0x292E42) // selection, raised rows
    static let terminalBlack = hex(0x414868)

    // Text
    static let fg = hex(0xC0CAF5)
    static let fgDim = hex(0xA9B1D6)
    static let comment = hex(0x565F89)     // muted / secondary copy

    // Accents
    static let blue = hex(0x7AA2F7)
    static let cyan = hex(0x7DCFFF)
    static let teal = hex(0x73DACA)
    static let green = hex(0x9ECE6A)
    static let yellow = hex(0xE0AF68)
    static let orange = hex(0xFF9E64)
    static let red = hex(0xF7768E)
    static let magenta = hex(0xBB9AF7)     // "purple" in tokyonight
    static let purple = magenta

    // Chrome
    static let border = hex(0x3B4261)
    static let line = hex(0x2F334D)

    /// Consistent accents for local presets and shared Crew activities.
    static func activity(_ emoji: String) -> Color {
        switch ActivityPreset(rawValue: emoji) {
        case .workout: return orange
        case .meal: return yellow
        case .coffee: return magenta
        case .focus: return cyan
        case .walk: return green
        case .toilet: return blue
        case nil: return yellow
        }
    }

    /// Raised row / card fill. `level` walks from a barely-there wash (0) to a
    /// hovered, clearly-lifted surface (3).
    static func surface(_ level: Int) -> Color {
        switch level {
        case 0:  return bgHighlight.opacity(0.30)
        case 1:  return bgHighlight.opacity(0.55)
        case 2:  return bgHighlight.opacity(0.80)
        default: return terminalBlack.opacity(0.75)
        }
    }

    /// Hairline stroke for cards and wells.
    static func stroke(_ strong: Bool = false) -> Color {
        strong ? border.opacity(0.85) : border.opacity(0.45)
    }
}

/// Cowboy Bebop send-off, shown on the empty states and in the HUD footer.
enum Bebop {
    static let signoff = "SEE YOU SPACE COWBOY…"
    static let sessionTitles = [
        "ASTEROID BLUES", "STRAY DOG STRUT", "HONKY TONK WOMEN",
        "GATEWAY SHUFFLE", "BALLAD OF FALLEN ANGELS", "SYMPATHY FOR THE DEVIL",
        "HEAVY METAL QUEEN", "WALTZ FOR VENUS", "JAMMING WITH EDWARD",
        "GANYMEDE ELEGY", "TOYS IN THE ATTIC", "JUPITER JAZZ",
        "COWBOY FUNK", "BRAIN SCRATCH", "HARD LUCK WOMAN", "THE REAL FOLK BLUES",
    ]

    /// A stable "session" title for this launch — picked once, never re-rolled,
    /// so the header doesn't flicker between renders.
    static let sessionTitle: String = sessionTitles.randomElement() ?? "ASTEROID BLUES"
}
