// cubi — AppKit top-level entry. No SwiftUI App/Scene: the only windows are the notch panel and
// the settings panel, both created by hand.

import AppKit
import CubiKit

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("cubi \(CubiInfo.version)")
    exit(0)
}

if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
    let ok = IconRenderer.render(to: arguments[i + 1])
    exit(ok ? 0 : 1)
}

// Offline preview of the island for layout work: --render-island <hidden|compact|expanded> <botState> <out.png>
if let i = arguments.firstIndex(of: "--render-island"), i + 3 < arguments.count {
    let ok = IconRenderer.renderIsland(mode: arguments[i + 1], botState: arguments[i + 2], to: arguments[i + 3])
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
