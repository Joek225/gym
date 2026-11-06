import AppKit

/// Solid, opaque colors (light and dark versions). Stage 3 makes these customizable.
@MainActor
enum Theme {
    static let toolbar    = color(light: 0xECECEC, dark: 0x2B2B2B)
    static let background = color(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let field      = color(light: 0xFFFFFF, dark: 0x3A3A3A)
    static let fieldBorder = color(light: 0xD0D0D0, dark: 0x4A4A4A)
    static let separator  = color(light: 0xD6D6D6, dark: 0x141414)
    static let text       = color(light: 0x1A1A1A, dark: 0xEDEDED)
    static let icon       = color(light: 0x4A4A4A, dark: 0xC8C8C8)
    static let mutedText  = color(light: 0x6E6E6E, dark: 0x9A9A9A)

    private static func color(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
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
