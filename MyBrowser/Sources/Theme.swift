import AppKit

/// Solid colors: your website's navy, plus the accent picked in Settings.
@MainActor
enum Theme {
    /// Your saved colors. `reload()` picks up changes from Settings (windows are then rebuilt).
    private static var saved = ThemeColors.load()
    static func reload() { saved = ThemeColors.load() }

    static var sidebar: NSColor { saved.sidebar }
    static var toolbar: NSColor { saved.toolbar }
    static var background: NSColor { saved.background }
    static var accent: NSColor { saved.accent }
    static let isDark = true
    /// Arc look: one soft gradient behind everything, with lighter and darker shades of it
    /// on top. It looks see-through but is all solid color (no blur), which saves energy.
    static let arcStyle = true
    private static func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }
    private static func black(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }

    static var field: NSColor { isDark ? white(0.12) : white(0.55) }
    /// The open tab is tinted with your accent, like the selected tab on your website.
    static var selectedTab: NSColor { accent.withAlphaComponent(0.30) }
    static var hoverTab: NSColor { isDark ? white(0.08) : white(0.38) }
    /// Dark text used on top of the bright group colors.
    static let sidebarText = NSColor(hex: 0x1C1E30)
    /// Background of the toolbar, bookmarks bar and sidebar (clear in Arc style, so the tint shows).
    static var chromeFill: NSColor { arcStyle ? .clear : saved.toolbar }
    static var sidebarFill: NSColor { arcStyle ? .clear : saved.sidebar }
    /// Small surfaces in the sidebar (pinned tiles, the Tools button).
    /// A soft fill for boxes on the white page area (like the new tab search box).
    static var pageBoxFill: NSColor { isDark ? field : black(0.04) }
    /// Thin outlines that suit light and dark themes.
    static var hairline: NSColor { NSColor(hex: 0x343849) }
    static var tileFill: NSColor { isDark ? white(0.07) : black(0.045) }
    static var buttonFill: NSColor { isDark ? white(0.12) : white(0.45) }
    static var text: NSColor { NSColor(hex: 0xE4E6EF) }
    static var mutedText: NSColor { NSColor(hex: 0x8E93A8) }
    static var icon: NSColor { isDark ? NSColor(hex: 0xC2C4D1) : NSColor(hex: 0x3C4043) }
    /// System controls (menus, alerts, text fields) in light or dark to match.
    static var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    private static func mix(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
        a.usingColorSpace(.sRGB)?.blended(withFraction: amount, of: b.usingColorSpace(.sRGB) ?? b) ?? a
    }
}

/// The browser's colors: the dark navy of your website, with one accent you pick.
/// (Fixed colors instead of fully custom ones: nothing to load or work out at launch.)
struct ThemeColors {
    var sidebar: NSColor
    var toolbar: NSColor
    var background: NSColor
    var accent: NSColor

    /// The four accents from your calendar.
    enum Accent: String, CaseIterable {
        case rose, periwinkle, sky, ocean
        var color: NSColor {
            switch self {
            case .rose:       NSColor(hex: 0xB65A6C)   // the "UPPER" / busy-day red
            case .periwinkle: NSColor(hex: 0x7192F2)   // the selected tab and today
            case .sky:        NSColor(hex: 0x7CC7F4)   // the event dots
            case .ocean:      NSColor(hex: 0x3A8BC7)   // the long event bars
            }
        }
        var name: String { rawValue.capitalized }
    }

    static var accentChoice: Accent {
        get { Accent(rawValue: UserDefaults.standard.string(forKey: "theme.accentChoice") ?? "") ?? .periwinkle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme.accentChoice") }
    }

    static func load() -> ThemeColors {
        ThemeColors(sidebar: NSColor(hex: 0x1D2030), toolbar: NSColor(hex: 0x252939),
                    background: NSColor(hex: 0x1D2030), accent: accentChoice.color)
    }
}

/// Chrome's nine tab group colors (dark theme versions).
enum GroupColor: String, Codable, CaseIterable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    var color: NSColor {
        switch self {
        case .grey:   NSColor(hex: 0xDADCE0)
        case .blue:   NSColor(hex: 0x8AB4F8)
        case .red:    NSColor(hex: 0xF28B82)
        case .yellow: NSColor(hex: 0xFDD663)
        case .green:  NSColor(hex: 0x81C995)
        case .pink:   NSColor(hex: 0xFF8BCB)
        case .purple: NSColor(hex: 0xC58AF9)
        case .cyan:   NSColor(hex: 0x87E3EB)
        case .orange: NSColor(hex: 0xFCAD70)
        }
    }

    var name: String { rawValue.capitalized }

    /// The darker version used for a turned-off group.
    var offColor: NSColor { color.blended(withFraction: 0.55, of: .black) ?? color }

    /// The darker chip color used on the bookmarks bar, like Chrome's saved groups.
    @MainActor var dimColor: NSColor {
        color.blended(withFraction: 0.75, of: Theme.toolbar) ?? color
    }

    /// A small colored dot for menus.
    func swatch(size: CGFloat = 12) -> NSImage {
        let fill = color
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "000000" }
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Small helpers for SF Symbols icons.
@MainActor
enum Icons {
    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
    static let globe = symbol("globe", size: 12)
    static let folder = symbol("folder", size: 12)
}
