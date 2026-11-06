import SwiftUI

/// Settings → 範圍: directories whose sessions never get a robot.
struct ScopeSection: View {
    let ignored: IgnoredDirectories
    @State private var text: String
    @Environment(\.settingChanged) private var settingChanged

    init(ignored: IgnoredDirectories) {
        self.ignored = ignored
        _text = State(initialValue: ignored.prefixes.joined(separator: "\n"))
    }

    var body: some View {
        DashCard(title: "忽略的目錄", icon: "eye.slash", help: "這些目錄開頭的 session 不會有機器人。一行一個，可用 ~。") {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 8).fill(Dash.background))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Dash.border))
                .onChange(of: text) { _, v in
                    ignored.prefixes = v.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    settingChanged()
                }
        }
    }
}
