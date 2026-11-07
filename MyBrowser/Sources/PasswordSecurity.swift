import AppKit
import CryptoKit
import Security

/// Extra password protections: leak checks, strength checks, a strong password generator,
/// and a clipboard that forgets copied passwords.
enum PasswordSecurity {
    /// How many times a password appears in known data leaks (0 = never), using the
    /// "Have I Been Pwned" service. The password itself is never sent: only the first 5
    /// characters of its fingerprint (hash) go out, and the match is checked on your Mac.
    static func leakCount(_ password: String) async -> Int? {
        let hash = Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
        let prefix = String(hash.prefix(5)), suffix = String(hash.dropFirst(5))
        guard let url = URL(string: "https://api.pwnedpasswords.com/range/\(prefix)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("true", forHTTPHeaderField: "Add-Padding")   // hides even how many results there were
        guard let result = try? await URLSession.shared.data(for: request),
              let text = String(data: result.0, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            if parts.count == 2, parts[0].uppercased() == suffix {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    /// A rough strength check: short, or only one kind of character, counts as weak.
    static func isWeak(_ password: String) -> Bool {
        let kinds = [password.contains(where: \.isLowercase), password.contains(where: \.isUppercase),
                     password.contains(where: \.isNumber), password.contains { !$0.isLetter && !$0.isNumber }]
        return password.count < 10 || kinds.filter { $0 }.count < 2
    }

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
