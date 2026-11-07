import AppKit

/// Solid, opaque colors. You pick four in Settings (or a preset theme);
/// the rest are worked out from those. Changes apply after a restart.
@MainActor
enum Theme {
    /// Your saved colors. `reload()` picks up changes from Settings (windows are then rebuilt).
    private static var saved = ThemeColors.load()
    static func reload() { saved = ThemeColors.load() }

    static var sidebar: NSColor { saved.sidebar }
    static var toolbar: NSColor { saved.toolbar }
    static var background: NSColor { saved.background }
    static var accent: NSColor { saved.accent }
    static var isDark: Bool { (saved.sidebar.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.55 }
    /// Arc look: one soft gradient behind everything, with lighter and darker shades of it
    /// on top. It looks see-through but is all solid color (no blur), which saves energy.
    static let arcStyle = true
    private static func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }
    private static func black(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }

    static var field: NSColor { isDark ? white(0.12) : white(0.55) }
    static var selectedTab: NSColor { isDark ? white(0.16) : white(0.78) }
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
    static var hairline: NSColor { isDark ? NSColor(hex: 0x4A4C62) : black(0.09) }
    static var tileFill: NSColor { isDark ? white(0.07) : black(0.045) }
    static var buttonFill: NSColor { isDark ? white(0.12) : white(0.45) }
    static var text: NSColor { isDark ? NSColor(hex: 0xE3E4EE) : NSColor(hex: 0x1F1F1F) }
    static var mutedText: NSColor { isDark ? NSColor(hex: 0x9C9EB2) : NSColor(hex: 0x5F6368) }
    static var icon: NSColor { isDark ? NSColor(hex: 0xC2C4D1) : NSColor(hex: 0x3C4043) }
    /// System controls (menus, alerts, text fields) in light or dark to match.
    static var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    private static func mix(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
        a.usingColorSpace(.sRGB)?.blended(withFraction: amount, of: b.usingColorSpace(.sRGB) ?? b) ?? a
    }
}

/// The four colors you choose, saved between launches.
struct ThemeColors {
    var sidebar: NSColor
    var toolbar: NSColor
    var background: NSColor
    var accent: NSColor

    struct Preset {
        let name: String
        let colors: ThemeColors
    }

    static let presets: [Preset] = [
        Preset(name: "Lavender (Arc)", colors: ThemeColors(sidebar: NSColor(hex: 0xCCD7F6), toolbar: NSColor(hex: 0xC4CCE7),
                                                           background: NSColor(hex: 0xFFFFFF), accent: NSColor(hex: 0x5B6EE1))),
        Preset(name: "Navy (your Chrome theme)", colors: ThemeColors(sidebar: NSColor(hex: 0x1C1E30), toolbar: NSColor(hex: 0x38394E),
                                                         background: NSColor(hex: 0x1C1E30), accent: NSColor(hex: 0x87E3EB))),
        Preset(name: "Graphite", colors: ThemeColors(sidebar: NSColor(hex: 0x1F1F1F), toolbar: NSColor(hex: 0x35363A),
                                                     background: NSColor(hex: 0x202124), accent: NSColor(hex: 0x8AB4F8))),
        Preset(name: "Light", colors: ThemeColors(sidebar: NSColor(hex: 0xF1F3F4), toolbar: NSColor(hex: 0xDEE1E6),
                                                  background: NSColor(hex: 0xFFFFFF), accent: NSColor(hex: 0x1A73E8))),
        Preset(name: "Forest", colors: ThemeColors(sidebar: NSColor(hex: 0x16221C), toolbar: NSColor(hex: 0x2A3D32),
                                                   background: NSColor(hex: 0x121A16), accent: NSColor(hex: 0x81C995))),
        Preset(name: "Plum", colors: ThemeColors(sidebar: NSColor(hex: 0x241A2B), toolbar: NSColor(hex: 0x3D2C49),
                                                 background: NSColor(hex: 0x1E1624), accent: NSColor(hex: 0xC58AF9))),
        Preset(name: "Sand", colors: ThemeColors(sidebar: NSColor(hex: 0xEFE8DC), toolbar: NSColor(hex: 0xDCCFB8),
                                                 background: NSColor(hex: 0xFBF8F2), accent: NSColor(hex: 0xB0703C))),
    ]

    static func load() -> ThemeColors {
        let d = UserDefaults.standard
        // One-time switch to the new Arc-style lavender look (you can still pick others in Settings).
        if !d.bool(forKey: "theme.lavenderDefault") {
            d.set(true, forKey: "theme.lavenderDefault")
            presets[0].colors.save()
        }
        let fallback = presets[0].colors
        func color(_ key: String, _ standard: NSColor) -> NSColor {
            guard let hex = d.string(forKey: "theme." + key), let value = UInt32(hex, radix: 16) else { return standard }
            return NSColor(hex: value)
        }
        return ThemeColors(sidebar: color("sidebar", fallback.sidebar), toolbar: color("toolbar", fallback.toolbar),
                           background: color("background", fallback.background), accent: color("accent", fallback.accent))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(sidebar.hexString, forKey: "theme.sidebar")
        d.set(toolbar.hexString, forKey: "theme.toolbar")
        d.set(background.hexString, forKey: "theme.background")
        d.set(accent.hexString, forKey: "theme.accent")
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
