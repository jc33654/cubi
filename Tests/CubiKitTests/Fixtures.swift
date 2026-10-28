import Foundation
import Testing
@testable import CubiKit

enum Fixtures {
    static let version = "claude-2.1.312"

    static func url(_ name: String) -> URL {
        guard let u = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(version)") else {
            fatalError("fixture \(name) missing")
        }
        return u
    }

    static func envelope(_ name: String) throws -> HookEnvelope {
        try HookEnvelope.parse(try Data(contentsOf: url(name)))
    }

    static func decoded(_ name: String) throws -> DecodedHook {
        let d = ClaudeCodeDecoder.decode(try envelope(name))
        try #require(d != nil, "fixture \(name) did not decode")
        return d!
    }

    static func all() throws -> [(String, HookEnvelope)] {
        guard let dir = Bundle.module.url(forResource: "Fixtures/\(version)", withExtension: nil) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.deletingPathExtension().lastPathComponent, try HookEnvelope.parse(try Data(contentsOf: $0))) }
    }
}
