import AppKit
import Security

/// A strong password generator, and a clipboard that forgets copied passwords.
enum PasswordSecurity {
    /// A strong random password like "kTq7Rm-x2PbwL-9eZvhN" (made with the Mac's secure random generator).
    static func generate() -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        var chars = bytes.map { letters[Int($0) % letters.count] }
        // Make sure there's at least one digit and one capital.
        chars[2] = Array("23456789")[Int(bytes[0]) % 8]
        chars[9] = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")[Int(bytes[1]) % 24]
        let s = String(chars)
        return [s.prefix(6), s.dropFirst(6).prefix(6), s.suffix(6)].map(String.init).joined(separator: "-")
    }
}

/// Copies passwords and clears them from the clipboard after a minute (if nothing else was copied since).
@MainActor
enum SecureClipboard {
    static func copy(_ secret: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Also asks clipboard managers and Universal Clipboard not to keep it.
        pb.setString(secret, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}
