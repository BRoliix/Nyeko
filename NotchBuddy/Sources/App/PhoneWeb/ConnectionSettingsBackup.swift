#if !APPSTORE
import Foundation

/// The phone-link settings that live in UserDefaults (relay address, the on switches, the web app's address) are also
/// kept in the Keychain, which survives what UserDefaults does not: deleting and reinstalling Nyeko, a reset of its
/// preferences (`defaults delete com.broliix.nyeko`), a clean-up tool. At launch, any of them missing from UserDefaults
/// comes back from the Keychain copy; afterwards every change is copied there again. The access key and the pairings
/// were already in the Keychain; with this, an update or a reinstall never asks for the relay again.
@MainActor
enum ConnectionSettingsBackup {
    private static let account = "nyeko-connection-settings"
    private static let keys = [
        NyekoPhoneService.relayKey, NyekoPhoneService.enabledKey, NyekoPhoneService.webAppKey,
        AndroidLinkService.enabledKey,
    ]
    private static var observer: NSObjectProtocol?
    private static var lastSaved = ""

    /// Call first thing at launch, before the phone link starts.
    static func restoreAndWatch() {
        let defaults = UserDefaults.standard
        if let raw = Keychain.load(key: account), let data = raw.data(using: .utf8),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = saved[key] { defaults.set(value, forKey: key) }
            }
        }
        save()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { save() } }
    }

    private static func save() {
        let defaults = UserDefaults.standard
        var out: [String: Any] = [:]
        for key in keys { if let value = defaults.object(forKey: key) { out[key] = value } }
        // Nothing worth keeping yet: leave an older copy alone rather than replace it with an empty one.
        guard !out.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let raw = String(data: data, encoding: .utf8), raw != lastSaved else { return }
        lastSaved = raw
        Keychain.save(key: account, value: raw)
    }
}
#endif
