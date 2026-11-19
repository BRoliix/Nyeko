#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Every coding session, one by one (Nyeko)
//
// The notch keeps one pill per client: two Claude Code sessions in VS Code share the VS Code pill, and the card shows
// the one that worked last. The session list shows them all — in the island (its own tab), in the window's Home and on
// the phone — each with where it runs, whether it works, idles or needs you, and a way to jump to it.

typealias LiveSession = PillSessionRegistry.Listed

enum SessionJump {
    /// Editors whose window for a folder comes forward when the folder is opened again.
    private static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed", "com.google.antigravity",
    ]

    /// "VS Code", "Cursor", "Warp", "Terminal"…
    static func hostName(_ s: LiveSession) -> String {
        if let host = s.hostApp { return ClaudeHost.name(for: host) }
        if !s.bundleId.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return ClaudeHost.name(for: nil)
    }

    static func folder(_ s: LiveSession) -> String {
        s.cwd.isEmpty ? "" : URL(fileURLWithPath: s.cwd).lastPathComponent
    }

    /// Brings the session's own window forward: an editor reopens the session's folder (its window comes to the front),
    /// a terminal app is activated.
    @MainActor
    static func open(_ s: LiveSession) {
        let app = s.hostApp ?? (s.bundleId.isEmpty ? nil : s.bundleId)
        if let app, editors.contains(app), !s.cwd.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            _ = TerminalTarget.activate(sessionBundleId: app)
        }
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    enum Status { case needsYou, working, idle }

    @MainActor
    static func status(_ s: LiveSession) -> Status {
        let state = AppState.shared
        if state.pendingApproval?.sessionId == s.session { return .needsYou }
        if state.waitingQuestions.contains(where: { $0.sessionId == s.session }) { return .needsYou }
        return s.isWorking ? .working : .idle
    }

    /// What the session is doing now, when it owns its pill's card (the card follows one session at a time).
    @MainActor
    static func currentStep(_ s: LiveSession) -> String? {
        guard s.isWorking, let task = AppState.shared.tasks.first(where: { $0.id == s.pill }),
              task.name == s.projectName else { return nil }
        return task.steps.indices.contains(task.stepIndex) ? task.steps[task.stepIndex] : task.steps.last
    }

    static func color(_ s: LiveSession) -> String {
        PillCatalog.definition(for: s.pill)?.color ?? "#C0C4CC"
    }
}

// MARK: - The island's session list (IslandView.sessions)

struct SessionListView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.liveSessions.isEmpty {
                VStack(spacing: 6) {
                    Text("No coding session is running.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(NyekoIsland.text)
                    Text("Start one in VS Code or a terminal (or with +): each session shows here.")
                        .font(.system(size: 11))
                        .foregroundColor(NyekoIsland.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(state.liveSessions) { s in
                            SessionRow(state: state, session: s)
                        }
                    }
                }
            }
            footer.frame(height: 34)
        }
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        let working = state.liveSessions.filter(\.isWorking).count
        return HStack {
            Text(state.liveSessions.isEmpty ? "" :
                 String(localized: "\(state.liveSessions.count) sessions · \(working) working"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(NyekoIsland.secondary)
            Spacer()
            MacChip(icon: "plus", title: String(localized: "New session")) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .launch }
            }
        }
        // Nyo sits in the bottom-left corner (viewLayouts[.sessions]).
        .padding(.leading, 40)
    }
}

private struct SessionRow: View {
    @ObservedObject var state: AppState
    let session: LiveSession
    @State private var hovered = false

    var body: some View {
        let status = SessionJump.status(session)
        Button(action: tap) {
            HStack(spacing: 10) {
                Circle().fill(Color(hex: SessionJump.color(session))).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(NyekoIsland.text)
                        .lineLimit(1)
                    Text(SessionJump.currentStep(session).map { "\(SessionJump.hostName(session)) · \($0)" }
                         ?? SessionJump.hostName(session))
                        .font(.system(size: 10.5))
                        .foregroundColor(NyekoIsland.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                chip(status)
                Image(systemName: status == .needsYou ? "hand.raised.fill" : "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(status == .needsYou ? NyekoIsland.tangerine : NyekoIsland.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovered ? 0.10 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(status == .needsYou ? String(localized: "Answer it here") : String(localized: "Open it"))
    }

    @ViewBuilder private func chip(_ status: SessionJump.Status) -> some View {
        switch status {
        case .needsYou:
            label(String(localized: "Needs you"), NyekoIsland.ink, NyekoIsland.tangerine)
        case .working:
            label(String(localized: "Working"), NyekoIsland.ink, NyekoIsland.mint)
        case .idle:
            Text(session.lastSeen, style: .relative)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(NyekoIsland.secondary)
                .lineLimit(1)
        }
    }

    private func label(_ text: String, _ fg: Color, _ bg: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(fg)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(bg))
    }

    /// Needs you: its request opens here. Otherwise: its window comes forward.
    private func tap() {
        if state.pendingApproval?.sessionId == session.session {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .approval }
        } else if state.waitingQuestions.contains(where: { $0.sessionId == session.session }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .question }
        } else {
            SessionJump.open(session)
        }
    }
}
#endif
