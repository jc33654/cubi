import Testing
import Foundation
@testable import CubiKit

// docs/plugins/manifest.schema.json must list exactly the keys Cubi reads (PluginManifest's key
// lists, which drive the unknown-key warning), and every field it lists must say how stable it is.
// Inputs: the two files themselves.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func schema() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: repo.appendingPathComponent("docs/plugins/manifest.schema.json")))
}

/// Follows a local `$ref` ("#/$defs/x").
private func resolve(_ node: JSONValue, in root: JSONValue) -> JSONValue {
    guard let ref = node["$ref"]?.string, ref.hasPrefix("#/$defs/") else { return node }
    return root["$defs"]?[String(ref.dropFirst("#/$defs/".count))] ?? node
}

/// The schema's own property names at `node`, as dotted paths, walking only where `keys` goes on.
private func compare(_ keys: PluginManifest.Keys, _ node: JSONValue, root: JSONValue, at path: String, extra: [String: JSONValue] = [:]) -> [String] {
    let node = resolve(node, in: root)
    switch keys {
    case .leaf:
        return []
    case .fields(let fields):
        var props = node["properties"]?.object ?? [:]
        props.merge(extra) { a, _ in a }
        var problems: [String] = []
        let want = Set(fields.keys), have = Set(props.keys)
        for k in want.subtracting(have).sorted() { problems.append("schema lacks \(path)\(k)") }
        for k in have.subtracting(want).sorted() { problems.append("schema has \(path)\(k), Cubi does not read it") }
        for (k, sub) in fields where props[k] != nil {
            problems += compare(sub, props[k]!, root: root, at: path + k + ".")
        }
        return problems
    case .each(let sub):
        let member = node["additionalProperties"] ?? node["items"] ?? .null
        return compare(sub, member, root: root, at: path + "*.")
    }
}

@Test func theSchemaListsExactlyTheKeysCubiReads() throws {
    let root = try schema()
    let common = root["properties"]?.object ?? [:]
    let tool = compare(PluginManifest.toolKeys, root["$defs"]!["tool"]!, root: root, at: "", extra: common)
    let agent = compare(PluginManifest.agentKeys, root["$defs"]!["agent"]!, root: root, at: "", extra: common)
    #expect(tool == [], "tool: \(tool)")
    #expect(agent == [], "agent: \(agent)")
}

@Test func everyFieldInTheSchemaSaysHowStableItIs() throws {
    let root = try schema()
    var missing: [String] = []
    // Fields are the members of every "properties" object. Not checked: members of an object that
    // carries a stability for the whole of itself (the agent map, an enum argument), the kind
    // constants that only pick a branch under $defs, and "if" conditions (not fields).
    func walk(_ v: JSONValue, _ path: String) {
        if let props = v["properties"]?.object, !(v["x-stability"] != nil && (path.hasSuffix(".map") || path.contains(".oneOf["))) {
            for (k, field) in props {
                let isBranchKind = k == "kind" && path.contains(".$defs.")
                if !isBranchKind, field["x-stability"] == nil { missing.append(path + "." + k) }
            }
        }
        for (k, child) in v.object ?? [:] where k != "if" { walk(child, path + "." + k) }
        for (i, child) in (v.array ?? []).enumerated() { walk(child, path + "[\(i)]") }
    }
    walk(root, "$")
    #expect(missing.sorted() == [], "\(missing.sorted())")
    // Only the three words.
    func values(_ v: JSONValue) -> [String] {
        (v["x-stability"]?.string.map { [$0] } ?? []) + (v.object?.values.flatMap(values) ?? []) + (v.array?.flatMap(values) ?? [])
    }
    #expect(Set(values(root)).isSubset(of: ["stable", "experimental", "deprecated"]))
}

@Test func theSchemaRefusesExactlyTheBuiltInActionNames() throws {
    let names = try #require(schema()["$defs"]?["tool"]?["properties"]?["commands"]?["propertyNames"]?["not"]?["enum"]?.array)
    #expect(Set(names.compactMap(\.string)) == ToolPlugin.reservedActions)
    #expect(names.count == ToolPlugin.reservedActions.count)
}
