import Foundation
import CubiKit

/// A blocking request the island is showing. The relay connection stays open until `decide`.
@MainActor
final class PendingRequest: Identifiable {
    enum Kind {
        case approval(tool: String, input: JSONValue, suggestions: JSONValue)
        case question(questions: [AskQuestion], raw: JSONValue)
    }

    let id = UUID()
    let sessionID: String
    let kind: Kind
    let connection: HookConnection
    let receivedAt = Date()

    init(sessionID: String, kind: Kind, connection: HookConnection) {
        self.sessionID = sessionID
        self.kind = kind
        self.connection = connection
    }
}

/// What the user chose on a card.
enum Decision: Sendable, Equatable {
    case allow
    case always
    case deny
    case answers([String: String])
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
