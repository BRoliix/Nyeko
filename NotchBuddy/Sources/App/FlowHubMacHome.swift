#if !APPSTORE
import AppKit
import SwiftUI

/// Nyeko → Home: the Mac at a glance. Ask Nyo, what is playing, today's events, the Notetaker,
/// your apps, this Mac (battery, volume, quick actions) and the coding sessions that run.
/// Everything is read when the page appears; nothing polls (0 % CPU when the window is shut).
struct HubMacHomePage: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var state = AppState.shared
    @Environment(\.hubVisible) private var visible

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = resolveUserFirstName()
        let part: String
        switch hour {
        case 5..<12:  part = String(localized: "Good morning")
        case 12..<18: part = String(localized: "Good afternoon")
        default:      part = String(localized: "Good evening")
        }
        if let name { return "\(part), \(name)" }
        return part
    }

    private var subtitle: String {
        let date = Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
        let sessions = state.liveSessions.count
        if sessions == 0 { return date }
        return String(localized: "\(date) · \(sessions) coding sessions running")
    }


    var body: some View {
        HubPageScaffold(title: greeting, subtitle: subtitle) {
            HubAskNyoCard(state: state)

            HStack(alignment: .top, spacing: 18) {
                HubNowPlayingCard(visible: visible)
                    .frame(maxWidth: .infinity)
                HubTodayCard()
                    .frame(width: 300)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 18, alignment: .top)],
                      alignment: .leading, spacing: 18) {
                HubNotetakerCard(router: router)
                HubNotificationsCard(visible: visible)
                HubQuickLaunchCard()
                HubThisMacCard(state: state)
            }

            if !state.liveSessions.isEmpty {
                HubSessionsCard(state: state, router: router)
            }
        }
    }
}

// MARK: - Card header

private struct HubCardTitle: View {
    let symbol: String
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(HubTheme.accentText)
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Spacer(minLength: 4)
            if let trailing, let action {
                Button(trailing, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(HubTheme.accentText)
            }
        }
    }
}

/// A round sticker button (play, next…).
private struct HubRoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 40
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .heavy))
                .foregroundColor(HubTheme.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(primary ? HubTheme.accent : HubTheme.card))
                .overlay(Circle().strokeBorder(HubTheme.ink, lineWidth: 2))
                .background(Circle().fill(HubTheme.ink).offset(x: 2, y: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Ask Nyo

private struct HubAskNyoCard: View {
    @ObservedObject var state: AppState
    @State private var text = ""
    @FocusState private var focused: Bool

    private var lastReply: String? {
        guard let last = state.chatHistory.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return nil }
        return last.content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(HubTheme.accentText)
                TextField(String(localized: "Ask Nyo anything: plan my day, explain an error, draft a message…"),
                          text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($focused)
                    .onSubmit(send)
                if state.stateOverride == .thinking {
                    ProgressView().controlSize(.small)
                }
                HubRoundButton(symbol: "arrow.up", label: String(localized: "Send"), size: 36, primary: true, action: send)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 56)
            .hubSticker(radius: 28, line: 2.5, shadow: 4)

            if let reply = lastReply {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        HubLiveMochi(size: 22)
                        Text("Nyo")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Button(String(localized: "Continue in the notch")) {
                            NotificationCenter.default.post(name: .hookExpand, object: IslandView.prompt)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(HubTheme.accentText)
                        Button(String(localized: "Clear")) {
                            state.chatHistory.removeAll()
                            ClaudeService.shared.clearConversation()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(HubTheme.secondary)
                    }
                    ScrollView {
                        Text(reply)
                            .font(.system(size: 14))
                            .foregroundColor(HubTheme.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(16)
                .hubSticker(radius: 18, fill: Color(hex: "#FFF1DF"), line: 2, shadow: 3)
            }
        }
    }

    private func send() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, state.stateOverride != .thinking else { return }
        text = ""
        state.chatHistory.append(ChatMessage(role: .user, content: query))
        state.stateOverride = .thinking
        Task {
            // A command ("open Figma", "pause", "start a timer") is done here, not asked.
            if let reply = await NyoActions.handle(query) {
                state.chatHistory.append(ChatMessage(role: .assistant, content: reply))
                state.stateOverride = nil
                return
            }
            await ClaudeService.shared.chat(query: query, context: nil, state: state)
        }
    }
}

// MARK: - Now playing

private struct HubNowPlayingCard: View {
    let visible: Bool
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var music = MusicController.shared
    @ObservedObject private var system = SystemNowPlaying.shared
    @ObservedObject private var state = AppState.shared
    @State private var watching = false

    var body: some View {
        HubCard {
            HubCardTitle(symbol: "music.note", title: String(localized: "Now playing"))
            if let np = NowPlayingDisplay.current() {
                player(np)
            } else {
                idle
            }
        }
        .onAppear { read(); setWatching(visible) }
        .onDisappear { setWatching(false) }
        .onChange(of: visible) { _, v in
            if v { read() }
            setWatching(v)
        }
    }

    private func read() {
        if spotify.isRunning, spotify.automationGranted { spotify.refresh() }
        if music.isRunning, music.automationGranted { music.refreshNow() }
    }

    /// Any app's Now Playing is read only while the window is on screen.
    private func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        if on { system.startWatching() } else { system.stopWatching() }
    }

    private func art(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    HubTheme.accent
                    Image(systemName: "music.note")
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundColor(HubTheme.ink)
                }
            }
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(HubTheme.ink, lineWidth: 2.5))
    }

    private func player(_ np: NowPlayingDisplay) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Button(action: np.open) { art(np.artwork) }
                .buttonStyle(.plain)
                .help(String(localized: "Open \(np.source)"))
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(np.title)
                        .font(.system(size: 21, weight: .bold))
                        .lineLimit(1)
                    Text(np.album.isEmpty ? np.artist : "\(np.artist) · \(np.album)")
                        .font(.system(size: 13.5))
                        .foregroundColor(HubTheme.secondary)
                        .lineLimit(1)
                    Text(np.playing ? String(localized: "Playing in \(np.source)") : String(localized: "Paused in \(np.source)"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(HubTheme.green)
                }
                if let duration = np.duration, duration > 0 {
                    TimelineView(.animation(minimumInterval: 1, paused: !(visible && np.playing))) { ctx in
                        let pos = np.position(ctx.date)
                        HStack(spacing: 8) {
                            Text(Self.clock(pos)).font(.system(size: 11.5, design: .monospaced))
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(hex: "#EEE3D3"))
                                    Capsule().fill(HubTheme.mint)
                                        .frame(width: geo.size.width * min(1, max(0, pos / duration)))
                                }
                                .overlay(Capsule().strokeBorder(HubTheme.ink, lineWidth: 1.5))
                            }
                            .frame(height: 9)
                            Text(Self.clock(duration)).font(.system(size: 11.5, design: .monospaced))
                        }
                        .foregroundColor(HubTheme.secondary)
                    }
                }
                HStack(spacing: 12) {
                    HubRoundButton(symbol: "backward.fill", label: String(localized: "Previous track"), action: np.previous)
                    HubRoundButton(symbol: np.playing ? "pause.fill" : "play.fill",
                                   label: np.playing ? String(localized: "Pause") : String(localized: "Play"),
                                   size: 48, primary: true, action: np.toggle)
                    HubRoundButton(symbol: "forward.fill", label: String(localized: "Next track"), action: np.next)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var idle: some View {
        HStack(spacing: 18) {
            art(nil)
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing playing")
                    .font(.system(size: 19, weight: .bold))
                Text("Play something in any app (Spotify, Music, YouTube in your browser…) and it shows here.")
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if spotify.isInstalled {
                        Button("Spotify") { spotify.openSpotify() }.buttonStyle(HubButtonStyle())
                    }
                    Button("Music") { music.openMusic() }.buttonStyle(HubButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Today

private struct HubTodayCard: View {
    @ObservedObject private var calendar = CalendarPeek.shared

    var body: some View {
        HubCard {
            HubCardTitle(symbol: "calendar", title: String(localized: "Today"),
                         trailing: calendar.access == .granted ? String(localized: "Calendar") : nil,
                         action: openCalendar)
            switch calendar.access {
            case .granted:
                if calendar.upcoming.isEmpty {
                    Text("Nothing else today or tomorrow.")
                        .font(.system(size: 13.5))
                        .foregroundColor(HubTheme.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(calendar.upcoming.enumerated()), id: \.offset) { _, e in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(e.color.map { Color(nsColor: $0) } ?? HubTheme.pink)
                                    .frame(width: 6, height: 36)
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(HubTheme.ink, lineWidth: 1.2))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title)
                                        .font(.system(size: 13.5, weight: .bold))
                                        .lineLimit(1)
                                    Text(CalendarPeek.when(e))
                                        .font(.system(size: 12))
                                        .foregroundColor(HubTheme.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            case .unknown:
                Text("See your next events here. Your calendar stays on this Mac.")
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Show my events")) { calendar.requestAccess() }
                    .buttonStyle(HubButtonStyle(primary: true))
            case .denied:
                Text("Calendar access is off for Nyeko.")
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
                Button(String(localized: "Open Settings")) { calendar.openPrivacySettings() }
                    .buttonStyle(HubButtonStyle())
            }
        }
        .onAppear { calendar.refresh() }
    }

    private func openCalendar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        }
    }
}

// MARK: - Notetaker

private struct HubNotetakerCard: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var notes = NoteTaker.shared

    var body: some View {
        HubCard {
            HubCardTitle(symbol: "record.circle", title: String(localized: "Notetaker"),
                         trailing: String(localized: "All notes"), action: { router.page = .notes })
            Button {
                notes.toggleFromPill()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: notes.isRecording ? "stop.fill" : "circle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(notes.isRecording ? String(localized: "Stop recording") : String(localized: "Record a meeting"))
                }
            }
            .buttonStyle(HubButtonStyle(primary: true))

            let recent = notes.notes.filter { $0.status != .recording }.prefix(3)
            if recent.isEmpty {
                Text("Your calls, transcribed person by person, with a summary. Audio stays on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent)) { note in
                        Button { router.page = .notes } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundColor(HubTheme.secondary)
                                Text(note.title)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Self.length(note))
                                    .font(.system(size: 12))
                                    .foregroundColor(HubTheme.secondary)
                            }
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(HubTheme.line)
                    }
                }
            }
        }
    }

    private static func length(_ note: Note) -> String {
        guard let end = note.end else { return "" }
        let minutes = max(1, Int((end.timeIntervalSince(note.start) / 60).rounded()))
        return String(localized: "\(minutes) min")
    }
}

// MARK: - Notifications

private struct HubNotificationsCard: View {
    let visible: Bool
    @ObservedObject private var feed = NotificationFeed.shared
    @ObservedObject private var whatsapp = WhatsAppController.shared
    @ObservedObject private var mail = MailController.shared
    @ObservedObject private var calendar = CalendarPeek.shared

    var body: some View {
        let items = Array(feed.items.prefix(5))
        HubCard {
            HubCardTitle(symbol: "bell", title: String(localized: "Notifications"),
                         trailing: feed.newCount > 0 ? String(localized: "Mark as seen") : nil,
                         action: { feed.markSeen() })
            if items.isEmpty {
                Text("Nothing new. WhatsApp, Mail and your next events show here.")
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { n in
                        Button { feed.open(n) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Group {
                                    if let icon = feed.icon(for: n) {
                                        Image(nsImage: icon).resizable().interpolation(.high)
                                    } else {
                                        Image(systemName: n.symbol)
                                            .font(.system(size: 13, weight: .bold))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(RoundedRectangle(cornerRadius: 7).fill(HubTheme.pink))
                                    }
                                }
                                .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(n.title)
                                            .font(.system(size: 13, weight: .bold))
                                            .lineLimit(1)
                                        if n.date > feed.seenUntil {
                                            Circle().fill(HubTheme.accent).frame(width: 7, height: 7)
                                        }
                                        Spacer(minLength: 4)
                                        Text(n.date, style: .relative)
                                            .font(.system(size: 11))
                                            .foregroundColor(HubTheme.muted)
                                            .lineLimit(1)
                                    }
                                    Text(n.body.isEmpty ? n.app : "\(n.app) · \(n.body)")
                                        .font(.system(size: 12))
                                        .foregroundColor(HubTheme.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(HubTheme.line)
                    }
                }
            }
            allAppsFooter
        }
        .onAppear { feed.refresh() }
        .onChange(of: visible) { _, v in if v { feed.refresh() } }
    }

    @ViewBuilder private var allAppsFooter: some View {
        switch feed.allApps {
        case .off:
            Button(String(localized: "Show every app's notifications…")) { feed.turnOnAllApps() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(HubTheme.accentText)
                .help(String(localized: "Reads macOS's Notification Center on this Mac. Needs Full Disk Access."))
        case .needsAccess:
            VStack(alignment: .leading, spacing: 6) {
                Text("To show every app, give Nyeko Full Disk Access (System Settings → Privacy & Security), then come back.")
                    .font(.system(size: 11.5))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(String(localized: "Open Settings")) { feed.openFullDiskAccessSettings() }
                        .buttonStyle(HubButtonStyle(primary: true))
                    Button(String(localized: "Turn off")) { feed.turnOffAllApps() }
                        .buttonStyle(HubButtonStyle())
                }
            }
        case .on:
            Button(String(localized: "Stop showing every app")) { feed.turnOffAllApps() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(HubTheme.muted)
        }
    }
}

// MARK: - Quick launch

private struct HubQuickLaunchCard: View {
    @ObservedObject private var launch = QuickLaunch.shared

    var body: some View {
        HubCard {
            HubCardTitle(symbol: "square.grid.2x2", title: String(localized: "Quick launch"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 12) {
                ForEach(launch.apps) { app in
                    Button {
                        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration(),
                                                           completionHandler: nil)
                    } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: launch.icon(for: app))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 42, height: 42)
                            Text(app.name)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open \(app.name)"))
                    .contextMenu {
                        Button(String(localized: "Remove from Quick launch")) { launch.remove(app.id) }
                    }
                }
                if launch.canAdd {
                    Button { launch.addWithPanel() } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 42, height: 42)
                                .overlay(RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(HubTheme.ink.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            Text("Add")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(HubTheme.secondary)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Also in the notch. Right-click an app to remove it.")
                .font(.system(size: 11.5))
                .foregroundColor(HubTheme.muted)
        }
    }
}

// MARK: - This Mac

private struct HubThisMacCard: View {
    @ObservedObject var state: AppState
    @ObservedObject private var doro = CoucoudoroController.shared
    @State private var battery: BatteryReading? = nil
    @State private var volume: Double = 50
    @State private var volumeRead = false

    var body: some View {
        HubCard {
            HubCardTitle(symbol: "laptopcomputer", title: String(localized: "This Mac"))
            if let battery {
                HStack(spacing: 8) {
                    Image(systemName: battery.symbol)
                        .font(.system(size: 18))
                        .foregroundColor(battery.percent < 20 && !battery.charging ? HubTheme.red : HubTheme.green)
                    Text(battery.charging ? String(localized: "\(battery.percent)% · charging")
                                          : String(localized: "\(battery.percent)% · on battery"))
                        .font(.system(size: 13.5, weight: .semibold))
                }
            }
            if volumeRead {
                HStack(spacing: 10) {
                    Image(systemName: volume < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .frame(width: 22)
                    Slider(value: $volume, in: 0...100, onEditingChanged: { editing in
                        if !editing { SystemVolume.set(Int(volume.rounded())) }
                    })
                    .accessibilityLabel(String(localized: "Volume"))
                    Text("\(Int(volume.rounded()))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(HubTheme.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                Button {
                    toggleNyodoro()
                } label: {
                    Label(doro.phase == .idle ? String(localized: "Nyodoro") : String(localized: "Stop timer"),
                          systemImage: doro.phase == .idle ? "timer" : "stop.circle")
                }
                .buttonStyle(HubButtonStyle())
                .help(String(localized: "Focus timer: 25 min of work, 5 min of rest"))
                Button {
                    QuickScreenshot.shared.take()
                } label: {
                    Label(String(localized: "Screenshot"), systemImage: "camera.viewfinder")
                }
                .buttonStyle(HubButtonStyle())
            }
        }
        .onAppear(perform: read)
    }

    private func read() {
        battery = BatteryReading.read()
        if let v = SystemVolume.get() {
            volume = Double(v)
            volumeRead = true
        }
    }

    private func toggleNyodoro() {
        if doro.phase != .idle { doro.end(); return }
        let id = CoucoudoroController.pillId
        if !state.activeIntegrations.contains(id) { state.toggleIntegration(id) }
        doro.begin()
    }
}

// MARK: - Coding sessions

/// Every live session, one by one (several in the same editor share one pill in the notch).
private struct HubSessionsCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var router: HubRouter

    var body: some View {
        HubCard {
            HubCardTitle(symbol: "terminal", title: String(localized: "Coding sessions"),
                         trailing: String(localized: "Agents settings"), action: { router.page = .agents })
            VStack(spacing: 0) {
                ForEach(state.liveSessions) { s in
                    let status = SessionJump.status(s)
                    Button {
                        if status == .needsYou {
                            NotificationCenter.default.post(name: .hookExpand,
                                object: state.pendingApproval?.sessionId == s.session ? IslandView.approval : IslandView.question)
                        } else {
                            SessionJump.open(s)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: SessionJump.color(s)))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(HubTheme.ink, lineWidth: 1.2))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.projectName)
                                    .font(.system(size: 14, weight: .bold))
                                    .lineLimit(1)
                                Text(SessionJump.currentStep(s).map { "\(SessionJump.hostName(s)) · \($0)" } ?? SessionJump.hostName(s))
                                    .font(.system(size: 12))
                                    .foregroundColor(HubTheme.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(status == .needsYou ? String(localized: "Needs you")
                                 : status == .working ? String(localized: "Working") : String(localized: "Idle"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(status == .needsYou ? HubTheme.accentText
                                                 : status == .working ? HubTheme.green : HubTheme.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Capsule().fill(HubTheme.card))
                                .overlay(Capsule().strokeBorder(HubTheme.ink, lineWidth: 1.5))
                        }
                        .frame(height: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(status == .needsYou ? String(localized: "Answer it in the notch") : String(localized: "Open it"))
                    Divider().overlay(HubTheme.line)
                }
            }
        }
    }
}
#endif
