import Foundation
import CubiKit

/// Runs each tool plugin's `tick` command on its own interval with every live session, and does
/// what the output asks for (calendar events). One run per plugin at a time; failures are logged
/// at most once per ten minutes per message.
@MainActor
final class PluginTicker {
    private let registry: PluginRegistry
    private let calendar: SystemCalendar
    private let input: () -> PluginIO.TickInput?
    private var timer: Timer?
    private var lastRun: [String: Date] = [:]
    private var running: Set<String> = []
    private var lastLogged: [String: Date] = [:]
    private static let logQuiet: TimeInterval = 600

    init(registry: PluginRegistry, calendar: SystemCalendar, input: @escaping () -> PluginIO.TickInput?) {
        self.registry = registry
        self.calendar = calendar
        self.input = input
    }

    func start() {
        let timer = Timer(timeInterval: Double(ToolPlugin.minTickInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        for tool in registry.tools {
            guard let hook = tool.tick, registry.isEnabled(tool.id), !running.contains(tool.id),
                  now.timeIntervalSince(lastRun[tool.id] ?? .distantPast) >= Double(hook.every) else { continue }
            lastRun[tool.id] = now
            Task { await run(tool, hook) }
        }
    }

    private func run(_ tool: ToolPlugin, _ hook: ToolPlugin.TickHook) async {
        running.insert(tool.id)
        defer { running.remove(tool.id) }
        guard let input = input() else { return }
        let out: String
        switch await ToolRunner.hook(tool, action: hook.action, json: input.json()) {
        case .success(let text): out = text
        case .failure(let f): logQuietly(tool.id, "run", "tick \(tool.id): \(f.message)"); return
        }
        let output: PluginIO.TickOutput
        do {
            output = try PluginIO.TickOutput.parse(out)
        } catch {
            logQuietly(tool.id, "parse", "tick \(tool.id): \(error.localizedDescription)")
            return
        }
        guard !output.calendar.isEmpty else { return }
        guard calendar.isReady else {
            logQuietly(tool.id, "calendar", "tick \(tool.id): 行事曆未設定，略過 \(output.calendar.count) 筆")
            return
        }
        do {
            let o = try calendar.write(output.calendar)
            if o.created + o.extended > 0 { CubiLog.write("tick \(tool.id): calendar +\(o.created) ~\(o.extended) =\(o.skipped)") }
        } catch {
            logQuietly(tool.id, "write", "tick \(tool.id): 行事曆寫入失敗：\(error.localizedDescription)")
        }
    }

    /// One line per (plugin, stage) per ten minutes, whatever the numbers in it say.
    private func logQuietly(_ tool: String, _ stage: String, _ message: String) {
        let key = tool + "/" + stage
        if let last = lastLogged[key], Date().timeIntervalSince(last) < Self.logQuiet { return }
        lastLogged[key] = Date()
        CubiLog.write(message)
    }
}
