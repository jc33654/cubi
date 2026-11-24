import Foundation
import CubiKit

// A tool plugin's panel and its service: `service.call` and `service.state` (ToolBridge).

extension PluginServices {
    /// A panel's `service.call` answered: the service's `reply`, or why there is none.
    struct CallResult {
        var ok: Bool
        var out: JSONValue?
        var err: String?
    }

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
        entry.replyBudget.called()
        return await withCheckedContinuation { continuation in
            // Waiting before the line goes out: its reply comes on the main queue, after this.
            entry.calls[callID] = continuation
            guard process.send(ServiceProtocol.call(id: callID, action: action, args: args)) else {
                entry.answer(callID, CallResult(ok: false, out: nil, err: "背景服務沒有在讀"))
                return
            }
            Task { @MainActor [weak entry] in
                try? await Task.sleep(for: ServiceProtocol.callTimeout)
                entry?.answer(callID, CallResult(ok: false, out: nil, err: "背景服務 \(ServiceProtocol.callTimeout.components.seconds) 秒內沒有回應"))
            }
        }
    }
}

extension PluginServices.Entry {
    /// Answers call `id` if it still waits; false if it does not.
    @discardableResult
    func answer(_ id: Int, _ result: PluginServices.CallResult) -> Bool {
        guard let waiting = calls.removeValue(forKey: id) else { return false }
        replyBudget.settled(waiting: calls.count)
        waiting.resume(returning: result)
        return true
    }

    /// Every call still waiting is answered with `why`.
    func endCalls(_ why: String) {
        let waiting = calls
        calls.removeAll()
        replyBudget.settled(waiting: 0)
        for continuation in waiting.values { continuation.resume(returning: PluginServices.CallResult(ok: false, out: nil, err: why)) }
    }
}
