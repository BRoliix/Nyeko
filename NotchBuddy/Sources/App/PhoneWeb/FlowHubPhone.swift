#if !APPSTORE
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Nyeko window → Phone: the relay, the switch, pairing (QR + copy), lock-screen alerts.
struct HubPhonePage: View {
    @ObservedObject private var phone = NyekoPhoneService.shared
    @State private var relay = NyekoPhoneService.shared.relayURL
    @State private var webApp = NyekoPhoneService.shared.webAppURL
    @State private var access = ""
    @State private var copied: String?
    @State private var confirmPairAgain = false
    @State private var confirmAndroidAgain = false
    @State private var showAndroid = false

    var body: some View {
        HubPageScaffold(title: String(localized: "Phone"),
                        subtitle: String(localized: "Nyeko in your pocket, through your own relay.")) {
            statusCard
            HubCard {
                HubLabel(String(localized: "1 · Your relay"))
                Text("The relay is a tiny Cloudflare Worker on your account (android/relay in the repo). It forwards encrypted frames and can read none of them.")
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                field(String(localized: "Relay address"), text: $relay, placeholder: "wss://nyeko-relay.you.workers.dev") {
                    phone.relayURL = relay
                    relay = phone.relayURL
                }
                .onChange(of: relay) { _, v in phone.relayURL = v }
                HStack(spacing: 10) {
                    SecureField(phone.hasAccessKey ? String(localized: "Access key saved · paste a new one to replace it")
                                                   : String(localized: "Access key (43 characters)"), text: $access)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .hubSticker(radius: 10, line: 1.5, shadow: 0)
                    Button(String(localized: "Save")) {
                        phone.setAccessKey(access)
                        access = ""
                    }
                    .buttonStyle(HubButtonStyle())
                    .disabled(access.trimmingCharacters(in: .whitespaces).count < 16)
                }
                Text("Stored in the Keychain.")
                    .font(.system(size: 11.5))
                    .foregroundColor(HubTheme.muted)
            }

            HubCard {
                HubLabel(String(localized: "2 · Turn it on"))
                Toggle(String(localized: "Let my phone reach Nyeko through the relay"),
                       isOn: Binding(get: { NyekoPhoneService.isEnabled }, set: { phone.setEnabled($0) }))
                    .font(.system(size: 13.5, weight: .semibold))
                    .disabled(relay.isEmpty || !phone.hasAccessKey)
            }

            pairingCard
            androidCard

            HubCard {
                HubLabel(String(localized: "Lock-screen alerts"))
                Text(phone.hasPush
                     ? String(localized: "On. When Claude needs you and the phone app is closed, your iPhone buzzes with “Nyo needs you”. The command itself never leaves the Mac.")
                     : String(localized: "Off. In the phone app (added to the Home Screen), tap Turn on alerts."))
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if phone.hasPush {
                    HStack(spacing: 10) {
                        Button(String(localized: "Send a test alert")) { WebPush.alert() }
                            .buttonStyle(HubButtonStyle())
                        Button(String(localized: "Turn off")) { phone.forgetPush() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let (text, color): (String, Color) = {
            switch phone.status {
            case .off: return (String(localized: "Off"), HubTheme.muted)
            case .notConfigured: return (String(localized: "Set the relay address and the access key first"), HubTheme.accentText)
            case .connecting: return (String(localized: "Connecting to the relay…"), HubTheme.secondary)
            case .waiting: return (String(localized: "Ready · waiting for your phone"), HubTheme.green)
            case .connected(let device): return (String(localized: "Connected to \(device)"), HubTheme.green)
            case .refused(let why): return (why, HubTheme.red)
            }
        }()
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(HubTheme.ink, lineWidth: 1.2))
            Text(text).font(.system(size: 14, weight: .bold))
            Spacer()
        }
        .padding(14)
        .hubSticker(radius: 14, line: 2, shadow: 3)
    }

    // MARK: Pairing

    private var pairingCard: some View {
        HubCard {
            HubLabel(String(localized: "3 · Pair your phone"))
            field(String(localized: "Web app address"), text: $webApp, placeholder: NyekoPhoneService.defaultWebApp) {
                phone.webAppURL = webApp
                webApp = phone.webAppURL
            }
            .onChange(of: webApp) { _, v in phone.webAppURL = v }
            if let link = phone.pairingLink(), let code = phone.pairingCode() {
                HStack(alignment: .top, spacing: 18) {
                    if let qr = Self.qr(link) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 220, height: 220)
                            .padding(8)
                            .background(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HubTheme.ink, lineWidth: 2))
                            .accessibilityLabel(String(localized: "Pairing QR code"))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("iPhone").font(.system(size: 12, weight: .heavy)).foregroundColor(HubTheme.muted)
                        step("1", String(localized: "Scan the code with the iPhone camera: Safari opens Nyeko."))
                        step("2", String(localized: "Share → Add to Home Screen, then open Nyeko from the Home Screen."))
                        step("3", String(localized: "Copy the pairing code here and tap Paste pairing code on the phone (Universal Clipboard)."))
                        Text("Android").font(.system(size: 12, weight: .heavy)).foregroundColor(HubTheme.muted)
                        step("1", String(localized: "Scan the same code with the camera: Chrome opens Nyeko."))
                        step("2", String(localized: "Tap Open in the Nyeko app: it pairs. Not installed yet? Tap Download the app, install it, then Open again."))
                        HStack(spacing: 10) {
                            Button(copied == "code" ? String(localized: "Copied") : String(localized: "Copy pairing code")) {
                                copy(code, as: "code")
                            }
                            .buttonStyle(HubButtonStyle(primary: true))
                            Button(copied == "link" ? String(localized: "Copied") : String(localized: "Copy link")) {
                                copy(link, as: "link")
                            }
                            .buttonStyle(HubButtonStyle())
                        }
                        Text("The code holds the keys of this pairing: share it with nobody. It is cleared from the clipboard after a minute.")
                            .font(.system(size: 11.5))
                            .foregroundColor(HubTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(String(localized: "Pair again…")) { confirmPairAgain = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(HubTheme.accentText)
                    .confirmationDialog(String(localized: "Pair again?"), isPresented: $confirmPairAgain) {
                        Button(String(localized: "Pair again"), role: .destructive) { phone.pairAgain() }
                    } message: {
                        Text("New keys: the phone paired now is cut off until you pair it again.")
                    }
            } else {
                Text("Save the relay address and the access key first.")
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
            }
        }
    }

    // MARK: The Android app (android/, built by the Actions "android" workflow)

    private var androidCard: some View {
        HubCard {
            HubLabel(String(localized: "4 · Nyeko for Android (the app)"))
            Text("The Android app adds what a web page can't: Nyo floating over your other apps, the island from the camera hole, widgets, and alerts that keep working. It has its own pairing, through the same relay.")
                .font(.system(size: 12.5))
                .foregroundColor(HubTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !phone.hasAccessKey || phone.relayURL.isEmpty {
                Text("Save the relay address and the access key first.")
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
            } else if !phone.androidPaired && !showAndroid {
                Button(String(localized: "Show the Android pairing code")) { showAndroid = true }
                    .buttonStyle(HubButtonStyle(primary: true))
            } else if let link = phone.androidPairingLink() {
                HStack(alignment: .top, spacing: 18) {
                    if let qr = Self.qr(link) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 168, height: 168)
                            .padding(8)
                            .background(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HubTheme.ink, lineWidth: 2))
                            .accessibilityLabel(String(localized: "Android pairing QR code"))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        step("1", String(localized: "On the phone, download the app from your Nyeko site: \(phone.webAppURL)/download.html"))
                        step("2", String(localized: "In the app: Pair, then scan this code with its camera."))
                        step("3", String(localized: "Settings → Nyo on your screen: allow Display over other apps."))
                        if case .connected(let d) = phone.links[.android] ?? .off {
                            Text("Connected to \(d)").font(.system(size: 12.5, weight: .bold)).foregroundColor(HubTheme.green)
                        }
                        Button(copied == "android" ? String(localized: "Copied") : String(localized: "Copy the link")) {
                            copy(link, as: "android")
                        }
                        .buttonStyle(HubButtonStyle())
                    }
                }
                Button(String(localized: "Pair the Android app again…")) { confirmAndroidAgain = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(HubTheme.accentText)
                    .confirmationDialog(String(localized: "Pair the Android app again?"), isPresented: $confirmAndroidAgain) {
                        Button(String(localized: "Pair again"), role: .destructive) { phone.pairAgain(.android) }
                    } message: {
                        Text("New keys: the Android phone is cut off until you scan the new code.")
                    }
            }
        }
    }

    private func copy(_ text: String, as what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
        let count = NSPasteboard.general.changeCount
        // The code is a secret: take it back off the clipboard after a minute, unless something else was copied since.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            MainActor.assumeIsolated {
                if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { if copied == what { copied = nil } }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(.system(size: 12, weight: .heavy))
                .frame(width: 22, height: 22)
                .background(Circle().fill(HubTheme.accent))
                .overlay(Circle().strokeBorder(HubTheme.ink, lineWidth: 1.5))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(HubTheme.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .hubSticker(radius: 10, line: 1.5, shadow: 0)
                .onSubmit(commit)
        }
        .onDisappear(perform: commit)
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
#endif
