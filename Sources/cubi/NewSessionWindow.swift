import AppKit
import SwiftUI
import CubiKit

/// The "open a new session" dialog: project directory, optional first message, what to continue
/// (nothing, the session it was opened from, or the project's last conversation), terminal. One
/// window, recreated each time so the prefill is fresh.
@MainActor
final class NewSessionWindow {
    /// The session the dialog was opened from: it can be continued, in its own project.
    struct From {
        let id: String
        let name: String
        let directory: String
    }

    private var window: NSWindow?
    private let recent: RecentProjects

    init(recent: RecentProjects) {
        self.recent = recent
    }

    func show(directory: String? = nil, terminal: TerminalKind? = nil, from: From? = nil) {
        window?.close()
        let recentPaths = recent.paths
        let view = NewSessionView(recent: recentPaths, directory: directory ?? recentPaths.first ?? "", terminal: terminal, from: from,
                                  continuing: .none,
                                  onStart: { [weak self] request in
                                      self?.recent.note(request.directory)
                                      self?.window?.close()
                                      Task { if let error = await SessionLauncher.launch(request) { SessionLauncher.alert(error) } }
                                  },
                                  onCancel: { [weak self] in self?.window?.close() })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "開新 session"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}

struct NewSessionView: View {
    let recent: [String]
    @State var directory: String
    @State var prompt = ""
    /// nil = automatic.
    @State var terminal: TerminalKind?
    let from: NewSessionWindow.From?
    @State var continuing: SessionLaunch.Resume
    /// Why the folder cannot be used; shown under it, and 開始 waits.
    @State private var refused: String?
    let onStart: (LaunchRequest) -> Void
    let onCancel: () -> Void

    private var choices: [String] {
        directory.isEmpty || recent.contains(directory) ? recent : [directory] + recent
    }

    /// The session it was opened from can only be continued in its own project (the same folder
    /// however it is written: a trailing slash from 瀏覽… is not another one).
    private var canContinueSession: Bool {
        from.map { ($0.directory as NSString).standardizingPath == (directory as NSString).standardizingPath } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("專案", selection: $directory) {
                    if choices.isEmpty { Text("（按「瀏覽…」選一個目錄）").tag("") }
                    ForEach(choices, id: \.self) { Text(PathFormat.abbreviatingHome($0, home: CubiPaths.home.path)).tag($0) }
                }
                Button("瀏覽…") { browse() }
            }
            if let refused {
                Text(refused).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("第一句話（選填，一開就送出）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            Picker("接續", selection: $continuing) {
                Text("新對話").tag(SessionLaunch.Resume.none)
                if let from, canContinueSession {
                    Text("接續這個 session（\(from.name)）").tag(SessionLaunch.Resume.session(from.id))
                }
                Text("接續這個專案上次的對話（claude --continue）").tag(SessionLaunch.Resume.last)
            }
            Picker("終端", selection: $terminal) {
                Text("自動（\(TerminalKind.automatic.displayName)）").tag(TerminalKind?.none)
                ForEach(TerminalKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            Spacer()
            HStack {
                Text("⌘↩ 開始").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("開始") { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(directory.isEmpty)
            }
        }
        .padding(16)
        .onChange(of: directory) {
            refused = nil
            // Another project: that session is not there to continue.
            if case .session = continuing, !canContinueSession { continuing = .none }
        }
    }

    private func start() {
        if let refusal = DirectoryGuard.refusal(directory) {
            refused = refusal.message
            return
        }
        onStart(LaunchRequest(directory: directory, prompt: prompt, resume: continuing, terminal: terminal ?? .automatic))
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選這個目錄"
        if !directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory) }
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
}
