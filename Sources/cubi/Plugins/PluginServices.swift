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

    /// A panel's `service.call` answered: the service's `reply`, or why there is none.
    struct CallResult {
        var ok: Bool
        var out: JSONValue?
        var err: String?
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
        var nextCall = 0
        var calls: [Int: CheckedContinuation<CallResult, Never>] = [:]
        /// Lines over the rate limit that may still be read for a reply: one per call made.
        var spareReads = 0

        /// Every call still waiting is answered with `why`.
        func endCalls(_ why: String) {
            let waiting = calls
            calls.removeAll()
            for continuation in waiting.values { continuation.resume(returning: CallResult(ok: false, out: nil, err: why)) }
        }

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
    /// A service's `state`, for its plugin's open panel.
    var onState: (String, JSONValue) -> Void = { _, _ in }

    init(registry: PluginRegistry, notice: @escaping ([String], String?) -> Void,
         present: @escaping (String, String, String, Bool) -> String?) {
        self.registry = registry
        self.notice = notice
        self.present = present
    }

    /// The services that should run, run; the others stop. Called on start, after a reload and when a switch changes.
    /// `only`: that plugin's alone, switch or not (an offline panel picture asked for it by name).
    func sync(only: String? = nil) {
        let wanted = registry.tools.filter { tool in
            tool.service != nil && registry.isEnabled(tool.id) && (only.map { $0 == tool.id } ?? registry.isServiceOn(tool.id))
        }
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
            entry.endCalls("Cubi 正在結束")
        }
        entries.removeAll()
    }

    // MARK: - From the panel

    /// The last `state` the plugin's service sent, if it runs.
    func state(of id: String) -> JSONValue? { entries[id]?.state }

    /// A panel's `service.call`: a `call` line to the service, answered by its `reply` with the same
    /// id, or by an error when it does not run, does not list `reply`, or says nothing in time.
    func call(_ id: String, action: String, args: JSONValue?) async -> CallResult {
        guard let entry = entries[id], let process = entry.process, !process.hasEnded else {
            return CallResult(ok: false, out: nil, err: "背景服務沒有在跑")
        }
        guard entry.spec.events.contains(.reply) else {
            return CallResult(ok: false, out: nil, err: "manifest 的 service.events 沒有列 reply")
        }
        entry.nextCall += 1
        let callID = entry.nextCall
        entry.spareReads += 1
        return await withCheckedContinuation { continuation in
            // Waiting before the line goes out: its reply comes on the main queue, after this.
            entry.calls[callID] = continuation
            guard process.send(ServiceProtocol.call(id: callID, action: action, args: args)) else {
                entry.calls.removeValue(forKey: callID)?.resume(returning: CallResult(ok: false, out: nil, err: "背景服務沒有在讀"))
                return
            }
            Task { @MainActor [weak entry] in
                try? await Task.sleep(for: ServiceProtocol.callTimeout)
                entry?.calls.removeValue(forKey: callID)?.resume(
                    returning: CallResult(ok: false, out: nil, err: "背景服務 \(ServiceProtocol.callTimeout.components.seconds) 秒內沒有回應"))
            }
        }
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
            entry.endCalls("背景服務關閉了")
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
            var event: Result<ServiceProtocol.Event, ServiceProtocol.Problem>?
            if !entry.lines.allow(at: .now) {
                // Over the limit, a reply to a call still waiting goes through: the panel asked for
                // it. Read only while one waits, only a line that can be a reply, and no more lines
                // than calls were made, so a flood is still dropped unread.
                let mayBeReply = !entry.calls.isEmpty && entry.spareReads > 0 && line.range(of: Data("\"reply\"".utf8)) != nil
                if mayBeReply { entry.spareReads -= 1 }
                let parsed = mayBeReply ? ServiceProtocol.event(line, allowed: entry.spec.events) : nil
                guard case .success(.reply(let callID, _, _))? = parsed, entry.calls[callID] != nil else {
                    return problem(entry, "一秒超過 \(ServiceProtocol.linesPerSecond) 行，多的丟掉")
                }
                event = parsed
            }
            switch event ?? ServiceProtocol.event(line, allowed: entry.spec.events) {
            case .failure(let p):
                problem(entry, p.localizedDescription)
            case .success(.log(let text)):
                if entry.logs.allow(at: .now) { CubiLog.write("service \(id): \(text)") }
            case .success(.state(let data)):
                entry.state = data
                onState(id, data)
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
            case .success(.reply(let callID, let ok, let out)):
                guard let waiting = entry.calls.removeValue(forKey: callID) else {
                    return problem(entry, "reply 的 id \(callID) 沒有在等的 call（已逾時或沒送過），丟掉")
                }
                waiting.resume(returning: CallResult(ok: ok, out: out, err: nil))
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
        entry.endCalls("背景服務結束了")
        // What it said no longer holds; an open panel hears so (`detail` null).
        if entry.state != nil {
            entry.state = nil
            onState(id, .null)
        }
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
