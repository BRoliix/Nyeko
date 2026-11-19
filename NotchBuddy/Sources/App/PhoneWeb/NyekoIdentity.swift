import Foundation
import Security

/// Nyeko: which computer this is, for a phone paired with several. Two macOS accounts on one Mac are two computers: each
/// has its own pairing, its own rooms and its own sessions, so each needs a name and an id of its own.
enum NyekoIdentity {
    private static let idDefault = "nyekoComputerID"

    /// "MacBook Pro · broly": the account's short name goes after the computer's, so two accounts on one Mac read apart.
    static func name() -> String {
        let host = (Host.current().localizedName ?? ProcessInfo.processInfo.hostName).trimmingCharacters(in: .whitespaces)
        let user = NSUserName()
        guard !user.isEmpty else { return String(host.prefix(48)) }
        return "\(host.prefix(32)) · \(user.prefix(14))"
    }

    /// A random id made once for this macOS account (UserDefaults: it names the computer, it unlocks nothing). The phone
    /// uses it to know that a new pairing code ("Pair again") is the same computer, and never confuses two accounts.
    static let id: String = {
        let d = UserDefaults.standard
        if let s = d.string(forKey: idDefault), s.range(of: "^[A-Za-z0-9_-]{16}$", options: .regularExpression) != nil { return s }
        var bytes = [UInt8](repeating: 0, count: 12)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<12).map { _ in UInt8.random(in: 0...255) }
        }
        let s = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        d.set(s, forKey: idDefault)
        return s
    }()
}
