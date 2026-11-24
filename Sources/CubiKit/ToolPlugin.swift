import Foundation

/// A tool plugin: an HTML panel plus a table of commands its JavaScript may run. Described by
/// `plugins/<id>/manifest.json` with `"kind": "tool"`. Nothing here runs anything: the app asks
/// `invocation(action:args:)` for an executable and arguments, checked against the declared
/// argument types, and runs that without a shell.
public struct ToolPlugin: Sendable, Equatable {
    public struct Panel: Sendable, Equatable {
        /// Absolute path of the HTML file, re-read every time the panel opens.
        public var file: String
        public var width: Double
        public var height: Double
        /// Name of the `window.webkit.messageHandlers.<bridge>` the page posts to.
        public var bridge: String
        /// `cubi`: the app puts its dashboard style kit (`cubi-` classes, light and dark) in
        /// front of the page's own styles. nil: the page is left alone.
        public var style: PanelStyle? = nil
    }

    public enum PanelStyle: String, Sendable, Equatable, CaseIterable { case cubi }

    public enum ArgType: Sendable, Equatable {
        /// `[A-Za-z0-9._-]`, 1–64 characters: file and asset names, never a path.
        case name
        /// Printable text up to 512 characters, not starting with `-` (so it cannot become an option).
        case value
        /// Free text up to 256 KB; only ever delivered on stdin.
        case text
        case choice([String])
    }

    public struct Command: Sendable, Equatable {
        /// argv, resolved: an absolute executable, then arguments; `$1`…`$n` stand for the caller's
        /// arguments (`$plugin` and relative executables were resolved when the manifest was parsed).
        public var run: [String]
        public var args: [ArgType]
        /// 1-based index of the argument fed on stdin instead of argv.
        public var stdin: Int?
        /// Treat stdout as a path and reveal it in the Finder.
        public var reveal: Bool
        /// A restricted session the plugin opens (`session.new` with `allowActions`) may run this
        /// command through `cubi --tool-run` without anyone being asked. Off unless the manifest
        /// says `"sessionAllowed": true` in so many words: it is there to be read.
        public var sessionAllowed: Bool = false
    }

    /// The commands a restricted session may be allowed to run (see `Command.sessionAllowed`).
    public var sessionActions: Set<String> { Set(commands.filter { $0.value.sessionAllowed }.keys) }

    public struct Invocation: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        public var stdin: String?
        public var reveal: Bool
        /// The plugin's own directory, the command's working directory.
        public var directory: String
    }

    /// `session.info`: the command that fills the plugin's section of a session's detail card.
    public struct SessionHook: Sendable, Equatable {
        public var info: String
        /// Seconds between refreshes while the session is selected.
        public var refresh: Int
    }

    /// `tick`: the command run every `every` seconds with all live sessions, whose output may
    /// ask the app for things only it can do (calendar events).
    public struct TickHook: Sendable, Equatable {
        public var action: String
        public var every: Int
    }

    public static let defaultBridge = "cubi"
    public static let textLimit = 262_144
    public static let minRefresh = 10
    public static let minTickInterval = 30
    /// Handled by the panel itself (native pickers, starting a Claude Code session, talking to the
    /// plugin's service); a manifest cannot take these names.
    public static let reservedActions: Set<String> = ["pick.file", "pick.dir", "session.new", "service.call", "service.state"]
    /// Built-ins a manifest has to ask for (`"builtins": […]`) because they reach outside the panel.
    public static let optionalBuiltins: Set<String> = ["session.new"]

    public var id: String
    public var displayName: String
    /// Where the manifest lives; `$plugin` in argv and relative executables resolve against it.
    public var directory: String
    public var panel: Panel
    public var commands: [String: Command]
    public var session: SessionHook?
    public var tick: TickHook?
    /// Optional built-ins the manifest asked for (see `optionalBuiltins`).
    public var builtins: Set<String> = []
    /// The command Cubi keeps running for this plugin, if any (experimental).
    public var service: Service? = nil
}
