import Foundation
import CubiKit

/// Runs the tool plugins' `service` programs (experimental): one per plugin that is on and whose
/// background-service switch is on. Reads their events, restarts them per `ServiceRestartPolicy`,
/// and reports what happened to the registry for the settings page.
@MainActor
final class PluginServices {
    struct Status: Equatable {
        enum Tone { case good, warning, danger, neutral }
        var text: String
        var tone: Tone
    }

    private final class Entry {
        let tool: ToolPlugin
        let spec: ToolPlugin.Service
        var policy: ServiceRestartPolicy
        var process: ServiceProcess?
        var token = UUID()
        var startedAt = ContinuousClock.now
        /// Cubi asked it to end: that end is not a failure.
        var stopping = false
        var relaunchAfterStop = false
        var restart: Task<Void, Never>?
        var reader = ServiceLineReader()
        var lines = ServiceRateLimit(count: ServiceProtocol.linesPerSecond, per: .seconds(1))
        var logs = ServiceRateLimit(count: ServiceProtocol.logsPerMinute, per: .seconds(60))
        var problems = ServiceRateLimit(count: 5, per: .seconds(60))
        var notices = ServiceRateLimit(count: 1, per: ServiceProtocol.noticeInterval)
        var tail = ServiceTail()
        var state: JSONValue?

        init(tool: ToolPlugin, spec: ToolPlugin.Service) {
            self.tool = tool
            self.spec = spec
            policy = ServiceRestartPolicy(restart: spec.restart)
        }
    }

    private let registry: PluginRegistry
    private var entries: [String: Entry] = [:]
    /// A `notice`: the lines for the island (ServiceProtocol.noticeLines) and a sound (ServiceProtocol.sounds).
    private let notice: ([String], String?) -> Void
    /// A `present`: effect, from, the plugin's name, whether the service shook the real window.
    /// nil when it was drawn, otherwise the `presented` failure.
    private let present: (String, String, String, Bool) -> String?

    init(registry: PluginRegistry, notice: @escaping ([String], String?) -> Void,
         present: @escaping (String, String, String, Bool) -> String?) {
        self.registry = registry
        self.notice = notice
        self.present = present
    }

    /// The services that should run, run; the others stop. Called on start, after a reload and when a switch changes.
    func sync() {
        let wanted = registry.tools.filter { $0.service != nil && registry.isEnabled($0.id) && registry.isServiceOn($0.id) }
        for (id, entry) in entries where !wanted.contains(entry.tool) {
            stop(id, entry)
        }
        for tool in wanted {
            if let entry = entries[tool.id] {
                if entry.stopping { entry.relaunchAfterStop = true }
            } else {
                launch(tool)
            }
        }
        for tool in registry.tools where tool.service != nil && !wanted.contains(tool) && entries[tool.id] == nil {
            report(tool.id, Status(text: "關閉", tone: .neutral))
        }
    }

    /// Cubi is quitting: every service ends now, whatever it does.
    func stopAll() {
        for entry in entries.values {
            entry.stopping = true
            entry.restart?.cancel()
            entry.process?.stopNow()
        }
        entries.removeAll()
    }

    // MARK: - One run

    private func launch(_ tool: ToolPlugin, policy: ServiceRestartPolicy? = nil) {
        guard let spec = tool.service, let invocation = tool.serviceInvocation else { return }
        let entry = Entry(tool: tool, spec: spec)
        if let policy { entry.policy = policy }
        entries[tool.id] = entry
        let id = tool.id, token = entry.token
        let environment = ProcessInfo.processInfo.environment.merging(["CUBI_BIN": ToolRunner.cubiBinary]) { _, ours in ours }
        do {
            entry.process = try ServiceProcess.start(
                invocation, environment: environment,
                // The main queue runs these in the order they come (Tasks need not): chunks stay in
                // order and the end comes after the last of them.
                onStdout: { data in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.stdout(id, token, data) } } },
                onStderr: { data in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.stderr(id, token, data) } } },
                onExit: { status in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.ended(id, token, status) } } })
        } catch {
            let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            CubiLog.write("service \(id): \(why)")
            entries[id] = nil
            report(id, Status(text: why, tone: .danger))
            return
        }
        entry.startedAt = .now
        entry.process?.send(ServiceProtocol.hello())
        CubiLog.write("service \(id): started (pid \(entry.process?.pid ?? 0))")
        report(id, Status(text: "執行中", tone: .good))
    }

    private func stop(_ id: String, _ entry: Entry) {
        entry.restart?.cancel()
        guard let process = entry.process, !process.hasEnded else {
            entries[id] = nil
            report(id, Status(text: "關閉", tone: .neutral))
            return
        }
        entry.stopping = true
        entry.relaunchAfterStop = false
        process.stop()
        CubiLog.write("service \(id): stopping")
        report(id, Status(text: "正在停止", tone: .neutral))
    }

    private func stderr(_ id: String, _ token: UUID, _ data: Data) {
        guard let entry = entries[id], entry.token == token else { return }
        entry.tail.append(data)
    }

    private func stdout(_ id: String, _ token: UUID, _ data: Data) {
        guard let entry = entries[id], entry.token == token else { return }
        for item in entry.reader.push(data) { take(item, entry) }
    }

    private func take(_ item: ServiceLineReader.Item, _ entry: Entry) {
        let id = entry.tool.id
        switch item {
        case .dropped(let n):
            problem(entry, ServiceProtocol.Problem.tooLong(n).localizedDescription)
        case .line(let line):
            guard entry.lines.allow(at: .now) else { return problem(entry, "一秒超過 \(ServiceProtocol.linesPerSecond) 行，多的丟掉") }
            switch ServiceProtocol.event(line, allowed: entry.spec.events) {
            case .failure(let p):
                problem(entry, p.localizedDescription)
            case .success(.log(let text)):
                if entry.logs.allow(at: .now) { CubiLog.write("service \(id): \(text)") }
            case .success(.state(let data)):
                entry.state = data
            case .success(.present(let requestID, let effect, let from, let windowShaken)):
                let failure = present(effect, from, entry.tool.displayName, windowShaken)
                if entry.process?.send(ServiceProtocol.presented(id: requestID, failure: failure)) == false {
                    problem(entry, "它沒在讀 stdin，回覆丟掉了")
                }
            case .success(.notice(let title, let body, let sound)):
                guard entry.notices.allow(at: .now) else {
                    return problem(entry, "notice 太密：\(ServiceProtocol.noticeInterval.components.seconds) 秒內只顯示一則，這則丟掉")
                }
                if let body, entry.logs.allow(at: .now) {
                    CubiLog.write("service \(id) notice: \(ServiceProtocol.quoted(title)) — \(ServiceProtocol.quoted(body, limit: ServiceProtocol.bodyLimit))")
                }
                notice(ServiceProtocol.noticeLines(title: title, plugin: entry.tool.displayName), sound)
            case .success(.reply):
                break
            }
        }
    }

    private func problem(_ entry: Entry, _ text: String) {
        if entry.problems.allow(at: .now) { CubiLog.write("service \(entry.tool.id): \(text)") }
    }

    private func ended(_ id: String, _ token: UUID, _ status: Int32) {
        guard let entry = entries[id], entry.token == token else { return }
        for item in entry.reader.finish() { take(item, entry) }
        let exit = ServiceExit(waitStatus: status)
        let how: String
        switch exit {
        case .code(let c): how = "exit \(c)"
        case .signal(let s): how = "signal \(s)"
        }
        let said = entry.tail.lastLine.map { "：\($0)" } ?? ""
        entry.process = nil
        let decision = entry.policy.decide(exit, startedAt: entry.startedAt, at: .now, askedToStop: entry.stopping)
        CubiLog.write("service \(id): ended (\(how)) → \(decision)\(said)")
        switch decision {
        case .stoppedByCubi:
            entries[id] = nil
            if entry.relaunchAfterStop, let tool = registry.tools.first(where: { $0.id == id }) {
                launch(tool)
            } else {
                report(id, Status(text: "關閉", tone: .neutral))
            }
        case .restart(let after):
            report(id, Status(text: "結束了（\(how)），\(after.components.seconds) 秒後重新啟動\(said)", tone: .warning))
            entry.restart = Task { @MainActor [weak self] in
                try? await Task.sleep(for: after)
                guard !Task.isCancelled, let self, self.entries[id] === entry, !entry.stopping else { return }
                self.entries[id] = nil
                self.launch(entry.tool, policy: entry.policy)
            }
        case .stopped:
            report(id, Status(text: "服務自己結束了（\(how)）；關掉再打開開關可以重新啟動", tone: .neutral))
        case .stoppedRightAway:
            report(id, Status(text: "一啟動就結束了（\(how)）\(said)", tone: .warning))
        case .failed:
            report(id, Status(text: "結束了（\(how)），設定為不重新啟動\(said)", tone: .danger))
        case .gaveUp(let n):
            report(id, Status(text: "10 分鐘內結束 \(n) 次，不再重新啟動\(said)；關掉再打開開關可以重試", tone: .danger))
        }
    }

    private func report(_ id: String, _ status: Status) {
        registry.serviceStatus[id] = status
    }
}
