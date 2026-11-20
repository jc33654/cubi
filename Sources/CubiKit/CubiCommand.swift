/// How `cubi` reads its command line: the mode is the first argument and nothing else. A flag
/// anywhere later is never a mode, in particular after `--tool-run <id> <action>`, where a
/// restricted session's allow rule (`…--tool-run <id> <action>:*`) lets it append whatever it likes.
/// (`cubi-hook` parses its own arguments; nothing here reaches it.)
public enum CubiCommand {
    /// Every mode `main.swift` handles. Anything else first, or nothing, starts the app.
    public static let modes: [String] = [
        "--version", "--validate-plugin", "--render-icon", "--probe-ghostty", "--render-island",
        "--render-panel", "--render-widget", "--render-settings",
        "--hooks-status", "--hooks-plan", "--install-hooks", "--uninstall-hooks",
        "--new-session", "--tool-run",
    ]

    /// `argv[1]` when it is a mode; nil otherwise (the app starts).
    public static func mode(_ argv: [String]) -> String? {
        argv.count > 1 && modes.contains(argv[1]) ? argv[1] : nil
    }

    public struct ToolRun: Sendable, Equatable {
        public var id: String
        public var action: String
        /// Everything after the action, flags included: they are the action's arguments, checked
        /// against its declared types like any others.
        public var args: [String]
    }

    /// `--tool-run <id> <action> [args…]`; nil when that is not the mode or the action is missing.
    public static func toolRun(_ argv: [String]) -> ToolRun? {
        guard mode(argv) == "--tool-run", argv.count > 3 else { return nil }
        return ToolRun(id: argv[2], action: argv[3], args: Array(argv[4...]))
    }
}
