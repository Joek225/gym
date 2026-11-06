import AppKit

/// Solid, opaque colors, taken from your Chrome screenshot (dark navy theme).
/// Stage 3 makes these customizable from a Settings panel.
@MainActor
enum Theme {
    static let sidebar     = NSColor(hex: 0x1C1E30)   // tab sidebar
    static let toolbar     = NSColor(hex: 0x38394E)   // toolbar + bookmarks bar
    static let field       = NSColor(hex: 0x232537)   // address bar
    static let background  = NSColor(hex: 0x1C1E30)   // behind web pages
    static let selectedTab = NSColor(hex: 0x38394E)
    static let hoverTab    = NSColor(hex: 0x2A2C41)
    static let text        = NSColor(hex: 0xE3E4EE)
    static let mutedText   = NSColor(hex: 0x9C9EB2)
    static let icon        = NSColor(hex: 0xC2C4D1)
    static let accent      = NSColor(hex: 0x87E3EB)
    /// Dark system controls (menus, alerts, text fields) to match the colors.
    static let appearance  = NSAppearance(named: .darkAqua)
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
