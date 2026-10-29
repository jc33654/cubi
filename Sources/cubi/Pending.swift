import Foundation
import CubiKit

/// A blocking request the island is showing. The relay connection stays open until `decide`.
@MainActor
final class PendingRequest: Identifiable {
    /// Which hook a question came through decides the reply shape.
    enum QuestionChannel { case preToolUse, permissionRequest }

    enum Kind {
        case approval(tool: String, input: JSONValue, suggestions: JSONValue)
        case question(questions: [AskQuestion], raw: JSONValue, channel: QuestionChannel)
    }

    var isQuestion: Bool { if case .question = kind { return true }; return false }

    /// What the plugin needs to build the reply.
    var context: PendingContext {
        switch kind {
        case .approval: return PendingContext(kind: .approval, envelope: envelope)
        case .question(_, _, .preToolUse): return PendingContext(kind: .questionPreToolUse, envelope: envelope)
        case .question(_, _, .permissionRequest): return PendingContext(kind: .questionPermission, envelope: envelope)
        }
    }

    let id = UUID()
    let sessionID: String
    let agent: String
    let kind: Kind
    let envelope: HookEnvelope
    let connection: HookConnection
    /// Id of the tool call being decided, when a PreToolUse for it was seen.
    let toolUseID: String?
    let receivedAt = Date()

    init(sessionID: String, agent: String, kind: Kind, envelope: HookEnvelope, connection: HookConnection, toolUseID: String?) {
        self.sessionID = sessionID
        self.agent = agent
        self.kind = kind
        self.envelope = envelope
        self.connection = connection
        self.toolUseID = toolUseID
    }
}

/// What the user chose on a card.
enum Decision: Sendable, Equatable {
    case allow
    case always
    case deny
    case answers([String: String])
    /// Close without a decision: the terminal's own prompt takes over.
    case deferToTerminal
}

/// View model for one card: everything SwiftUI needs, nothing it must not touch.
struct PendingCard: Identifiable, Equatable {
    enum Content: Equatable {
        case approval(title: String, detail: String, canAlways: Bool)
        case question([AskQuestion])
    }
    let id: UUID
    let sessionName: String
    let color: RGB
    let content: Content
}
