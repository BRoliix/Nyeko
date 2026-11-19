#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Mac home (Nyeko): the island's home for the Mac
//
//  ┌ Now playing ───────────────┐ ┌ Next up ──────────┐
//  │ art  title / artist        │ └───────────────────┘
//  │ ━━━━━━━━━━━━  ◀◀  ▶  ▶▶    │ ┌ Notetaker ────────┐
//  └────────────────────────────┘ └───────────────────┘
//   [app] [app] [app] [app] [app] [+]
//   Nyo  (Ask Nyo) (Nyodoro) (Screenshot) (Dashboard)      82 %
//
// Height: IslandConst.viewLayouts[.mac] (Nyo sits bottom-left, beside the actions).

struct MacHomeView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var calendar = CalendarPeek.shared
    @ObservedObject private var notes = NoteTaker.shared
    @ObservedObject private var launch = QuickLaunch.shared
    @ObservedObject private var doro = CoucoudoroController.shared
    @ObservedObject private var feed = NotificationFeed.shared
    @Environment(\.islandViewActive) private var active
    @State private var battery: BatteryReading? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                MacNowPlayingCard(state: state, live: active && state.mode == .expanded)
                    .frame(width: 330, height: 112)
                VStack(spacing: 8) {
                    nextUpCard.frame(height: 52)
                    notetakerCard.frame(height: 52)
                }
                .frame(maxWidth: .infinity)
            }
            appsRow.frame(height: 40)
            actionsRow.frame(height: 34)
        }
        .onAppear { if active { refresh() } }
        .onChange(of: active) { _, on in if on { refresh() } }
        .onChange(of: state.mode) { _, mode in
            if mode == .expanded && state.view == .mac { refresh() }
        }
    }

    private func refresh() {
        battery = BatteryReading.read()
        feed.refresh()
        // Spotify and Music post their state only on a change: read what is playing now,
        // when macOS already lets Nyeko (no Automation prompt on its own).
        let spotify = SpotifyController.shared
        if spotify.isRunning, spotify.automationGranted { spotify.refresh() }
        let music = MusicController.shared
        if music.isRunning, music.automationGranted { music.refreshNow() }
    }

    private func collapse() {
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    // MARK: Next up

    private var nextUpCard: some View {
        CardBackground(wash: nil) {
            Button(action: nextUpAction) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(calendar.next?.color.map { Color(nsColor: $0) } ?? NyekoIsland.pink)
                        .frame(width: 4, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        MacEyebrow(text: String(localized: "Next up"))
                        switch calendar.access {
                        case .granted:
                            if let e = calendar.next {
                                Text(e.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(NyekoIsland.text)
                                    .lineLimit(1)
                                Text(CalendarPeek.when(e))
                                    .font(.system(size: 11))
                                    .foregroundColor(NyekoIsland.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("Nothing else today")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(NyekoIsland.secondary)
                            }
                        case .unknown:
                            Text("Show my next event")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(NyekoIsland.tangerine)
                        case .denied:
                            Text("Allow Calendar in Settings")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(NyekoIsland.tangerine)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func nextUpAction() {
        switch calendar.access {
        case .unknown: calendar.requestAccess()
        case .denied: calendar.openPrivacySettings()
        case .granted:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                                   completionHandler: nil)
                collapse()
            }
        }
    }

    // MARK: Notetaker

    private var notetakerCard: some View {
        CardBackground(wash: notes.isRecording ? .red : nil) {
            HStack(spacing: 10) {
                Button(action: { notes.toggleFromPill() }) {
                    HStack(spacing: 5) {
                        Image(systemName: notes.isRecording ? "stop.fill" : "record.circle")
                            .font(.system(size: 11, weight: .bold))
                        Text(notes.isRecording ? "Stop" : "Record")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundColor(NyekoIsland.ink)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Capsule().fill(notes.isRecording ? NyekoIsland.cream : NyekoIsland.pink))
                }
                .buttonStyle(.plain)
                .help(notes.isRecording ? String(localized: "Stop and write the notes")
                                        : String(localized: "Record a meeting with the Notetaker"))

                Button(action: { FlowHubController.shared.show(.notes); collapse() }) {
                    VStack(alignment: .leading, spacing: 2) {
                        MacEyebrow(text: String(localized: "Notetaker"))
                        Text(notetakerLine)
                            .font(.system(size: 11))
                            .foregroundColor(NyekoIsland.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var notetakerLine: String {
        if let rec = notes.recording {
            return String(localized: "Recording · \(rec.title)")
        }
        guard let last = notes.notes.first(where: { $0.status != .recording }) else {
            return String(localized: "Your notes stay on this Mac")
        }
        if let end = last.end {
            let minutes = max(1, Int((end.timeIntervalSince(last.start) / 60).rounded()))
            return String(localized: "\(last.title) · \(minutes) min")
        }
        return last.title
    }

    // MARK: Apps

    private var appsRow: some View {
        HStack(spacing: 12) {
            ForEach(launch.apps) { app in
                MacAppButton(app: app, icon: launch.icon(for: app))
            }
            if launch.canAdd {
                Button(action: { launch.addWithPanel() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(NyekoIsland.secondary)
                        .frame(width: 34, height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Add an app"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 7) {
            MacChip(icon: "sparkles", title: String(localized: "Ask Nyo"), primary: true) {
                if state.promptContext == nil {
                    state.promptContext = WindowContextCapture.captureActive(from: state.lastExternalApp)
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .prompt }
            }
            MacChip(icon: doro.phase == .idle ? "timer" : "stop.circle",
                    title: doro.phase == .idle ? String(localized: "Nyodoro") : String(localized: "Stop timer")) {
                toggleNyodoro()
            }
            MacChip(icon: "camera.viewfinder", title: String(localized: "Screenshot")) {
                collapse()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    MainActor.assumeIsolated { QuickScreenshot.shared.take() }
                }
            }
            MacChip(icon: "rectangle.grid.2x2", title: String(localized: "Dashboard")) {
                FlowHubController.shared.show()
                collapse()
            }
            Spacer(minLength: 4)
            let newCount = feed.newCount
            if newCount > 0 {
                Button {
                    FlowHubController.shared.show(.home)
                    collapse()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bell.fill").font(.system(size: 11, weight: .bold))
                        Text("\(newCount)").font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundColor(NyekoIsland.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(NyekoIsland.pink))
                }
                .buttonStyle(.plain)
                .help(String(localized: "\(newCount) new notifications: open them in Nyeko"))
            }
            if let battery {
                HStack(spacing: 4) {
                    Image(systemName: battery.symbol)
                        .font(.system(size: 13))
                        .foregroundColor(battery.percent < 20 && !battery.charging ? Color(hex: "#F4505E") : NyekoIsland.mint)
                    Text("\(battery.percent)%")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(NyekoIsland.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Battery \(battery.percent)%"))
            }
        }
        // Nyo sits in the bottom-left corner (viewLayouts[.mac]): leave him room.
        .padding(.leading, 46)
        .padding(.trailing, 8)
    }

    private func toggleNyodoro() {
        if doro.phase != .idle {
            doro.end()
            return
        }
        let id = CoucoudoroController.pillId
        if !state.activeIntegrations.contains(id) {
            state.toggleIntegration(id)
        }
        doro.begin()
    }
}

// MARK: - Now playing

struct MacNowPlayingCard: View {
    @ObservedObject var state: AppState
    /// The island is open on this view: the progress bar may move, and any app's Now Playing is read.
    let live: Bool
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var music = MusicController.shared
    @ObservedObject private var system = SystemNowPlaying.shared
    @State private var watching = false

    var body: some View {
        CardBackground(wash: nil) {
            Group {
                if let np = NowPlayingDisplay.current() {
                    player(np)
                } else {
                    idle
                }
            }
            .padding(12)
        }
        .onAppear { setWatching(live) }
        .onDisappear { setWatching(false) }
        .onChange(of: live) { _, on in setWatching(on) }
    }

    /// Reads any app's Now Playing only while the island shows this card.
    private func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        if on { system.startWatching() } else { system.stopWatching() }
    }

    private func artworkView(_ image: NSImage?, size: CGFloat) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    NyekoIsland.tangerine
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundColor(NyekoIsland.ink)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func player(_ np: NowPlayingDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: np.open) {
                HStack(spacing: 10) {
                    artworkView(np.artwork, size: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        MacEyebrow(text: np.playing ? String(localized: "Now playing · \(np.source)")
                                                    : String(localized: "Paused · \(np.source)"))
                        Text(np.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(NyekoIsland.text)
                            .lineLimit(1)
                        Text(np.artist)
                            .font(.system(size: 11))
                            .foregroundColor(NyekoIsland.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open \(np.source)"))

            HStack(spacing: 8) {
                progress(np)
                MacRoundButton(symbol: "backward.fill", label: String(localized: "Previous track"), size: 26, action: np.previous)
                MacRoundButton(symbol: np.playing ? "pause.fill" : "play.fill",
                               label: np.playing ? String(localized: "Pause") : String(localized: "Play"),
                               size: 30, primary: true, action: np.toggle)
                MacRoundButton(symbol: "forward.fill", label: String(localized: "Next track"), size: 26, action: np.next)
            }
            .frame(height: 30)
        }
    }

    /// Drawn once a second, only while the island is open on this view and the track plays.
    @ViewBuilder
    private func progress(_ np: NowPlayingDisplay) -> some View {
        if let duration = np.duration, duration > 0 {
            TimelineView(.animation(minimumInterval: 1, paused: !(live && np.playing))) { context in
                let fraction = min(1, max(0, np.position(context.date) / duration))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(NyekoIsland.mint)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
        } else {
            Spacer(minLength: 0)
        }
    }

    private var idle: some View {
        HStack(spacing: 10) {
            artworkView(nil, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing playing")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(NyekoIsland.text)
                Text("Play something in any app: it shows here.")
                    .font(.system(size: 10.5))
                    .foregroundColor(NyekoIsland.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if spotify.isInstalled {
                        MacChip(icon: "music.note.list", title: "Spotify") { spotify.openSpotify() }
                    }
                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil {
                        MacChip(icon: "music.note", title: "Music") { music.openMusic() }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Small parts

struct MacEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(NyekoIsland.secondary)
            .lineLimit(1)
    }
}

struct MacRoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    var primary = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundColor(primary ? NyekoIsland.ink : NyekoIsland.text)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(primary ? NyekoIsland.tangerine
                                          : Color.white.opacity(hovered ? 0.16 : 0.09))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MacChip: View {
    let icon: String
    let title: String
    var primary = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(primary ? NyekoIsland.ink : NyekoIsland.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule().fill(primary ? NyekoIsland.tangerine.opacity(hovered ? 0.88 : 1)
                                       : Color.white.opacity(hovered ? 0.15 : 0.08))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(primary ? 0 : 0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct MacAppButton: View {
    let app: QuickLaunch.Item
    let icon: NSImage
    @State private var hovered = false

    var body: some View {
        Button(action: { QuickLaunch.shared.open(app) }) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .scaleEffect(hovered ? 1.12 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(app.name)
        .accessibilityLabel(String(localized: "Open \(app.name)"))
        .contextMenu {
            Button(String(localized: "Remove from the island")) { QuickLaunch.shared.remove(app.id) }
        }
    }
}
#endif
