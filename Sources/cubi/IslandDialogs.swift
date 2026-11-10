import AppKit

/// A one-line question from a plugin's card (the island has no text fields of its own), awaited
/// rather than run modally so the app keeps running.
@MainActor
final class LinePrompt: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var field: NSTextField?
    private var answer: CheckedContinuation<String?, Never>?

    /// The typed line, or nil when cancelled or closed. A new question replaces one still open
    /// (that one is answered nil), so the panel always shows what the last click asked.
    func ask(_ prompt: String) async -> String? {
        if answer != nil { CubiLog.write("line prompt: replaced by a newer question, the open one counts as cancelled") }
        finish(nil)
        return await withCheckedContinuation { continuation in
            answer = continuation
            show(prompt)
        }
    }

    private func show(_ prompt: String) {
        let field = NSTextField(string: "")
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "確定", target: self, action: #selector(confirmed))
        ok.keyEquivalent = "\r"
        let p = floatingPanel([NSTextField(wrappingLabelWithString: prompt), field], buttons: [cancel, ok], width: 300)
        p.delegate = self
        p.initialFirstResponder = field
        panel = p
        self.field = field
        present(p)
    }

    @objc private func confirmed() { finish(field?.stringValue) }
    @objc private func cancelled() { finish(nil) }

    func windowWillClose(_ notification: Notification) {
        panel = nil                                  // already closing: finish must not close it again
        finish(nil)
    }

    private func finish(_ line: String?) {
        guard let answer else { return }
        self.answer = nil
        let p = panel
        panel = nil
        field = nil
        p?.close()
        answer.resume(returning: line)
    }
}

/// A message raised from the island (why a terminal would not open…), with only 好. Not an
/// NSAlert: its modal level sits under the expanded island, which would hide it and stop the app.
@MainActor
enum Notice {
    private static var panel: NSPanel?

    /// A new notice replaces one still open.
    static func show(_ title: String, _ text: String) {
        panel?.close()
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)
        let ok = NSButton(title: "好", target: nil, action: #selector(NSWindow.performClose(_:)))
        ok.keyEquivalent = "\r"
        let p = floatingPanel([heading, NSTextField(wrappingLabelWithString: text)], buttons: [ok], width: 360)
        ok.target = p
        panel = p
        present(p)
    }
}

/// Rows, then the buttons on the right; one level above the island (IslandPanel), which can cover
/// the middle of the screen when expanded, on every space, and kept when Cubi is not active.
@MainActor
private func floatingPanel(_ rows: [NSView], buttons: [NSButton], width: CGFloat) -> NSPanel {
    let row = NSStackView(views: [NSView()] + buttons)
    let stack = NSStackView(views: rows + [row])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
    row.widthAnchor.constraint(equalToConstant: width).isActive = true
    rows.compactMap { $0 as? NSTextField }.filter { !$0.isEditable }.forEach { $0.preferredMaxLayoutWidth = width }

    let p = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    p.title = "Cubi"
    p.contentView = stack
    p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.setContentSize(stack.fittingSize)
    p.center()
    return p
}

@MainActor
private func present(_ panel: NSPanel) {
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
}
