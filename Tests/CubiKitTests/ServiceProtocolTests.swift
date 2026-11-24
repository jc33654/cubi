import Testing
import Foundation
@testable import CubiKit

// Inputs: lines made by PluginIO.encode (the app's own JSON writer) or by ServiceProtocol's own
// encoders. Every value in them is a constant from the code (ServiceProtocol's limits and name
// sets, the ServiceEvent names, the protocol version) or derived from one (one over a limit, a
// character from a name repeated); 1e300 is the value ToolPlugin.seconds names as trapping Int(Double);
// "send" is the action the LAN Nudge plan (b57, plan v2 section 2) passes through service.call.

private typealias P = ServiceProtocol
private let all = Set(ToolPlugin.ServiceEvent.allCases)

private func line(_ o: [String: JSONValue]) -> Data { Data(PluginIO.encode(JSONValue.object(o)).utf8) }
private func event(_ o: [String: JSONValue], allowed: Set<ToolPlugin.ServiceEvent> = all) -> Result<P.Event, P.Problem> {
    P.event(line(o), allowed: allowed)
}
private func s(_ x: String) -> JSONValue { .string(x) }
private func n(_ x: Double) -> JSONValue { .number(x) }
/// `count` characters, made of the first letter of a sound name.
private func chars(_ count: Int) -> String { String(repeating: String(P.sounds.sorted()[0].first!), count: count) }

@Test func everyEventParsesWithItsFieldsAndDefaults() throws {
    let knock = P.sounds.sorted()[0], shake = "shake"
    #expect(P.effects.contains(shake))
    #expect(event(["type": s("notice"), "title": s(knock)]) == .success(.notice(title: knock, body: nil, sound: nil)))
    #expect(event(["type": s("notice"), "title": s(knock), "body": s(shake), "sound": s(knock)]) == .success(.notice(title: knock, body: shake, sound: knock)))
    #expect(event(["type": s("present"), "id": n(0), "effect": s(shake), "from": s(knock)]) == .success(.present(id: 0, effect: shake, from: knock, windowShaken: false)))
    #expect(event(["type": s("present"), "id": n(1), "effect": s(shake), "from": s(knock), "windowShaken": .bool(true)]) == .success(.present(id: 1, effect: shake, from: knock, windowShaken: true)))
    let data = try JSONDecoder().decode(JSONValue.self, from: Data(P.hello().utf8))
    #expect(event(["type": s("state"), "data": data]) == .success(.state(data)))
    #expect(event(["type": s("log"), "text": s(knock)]) == .success(.log(knock)))
    #expect(event(["type": s("reply"), "id": n(2), "ok": .bool(false)]) == .success(.reply(id: 2, ok: false, out: nil)))
    #expect(event(["type": s("reply"), "id": n(2), "ok": .bool(true), "out": data]) == .success(.reply(id: 2, ok: true, out: data)))
    // Every kind maps back to its manifest name.
    for k in ToolPlugin.ServiceEvent.allCases {
        let o: [String: JSONValue] = ["type": s(k.rawValue), "title": s(knock), "text": s(knock), "id": n(0), "effect": s(shake),
                                      "from": s(knock), "data": data, "ok": .bool(true)]
        #expect(try event(o).get().kind == k)
    }
}

@Test func onlyDeclaredKnownObjectLinesWithinTheLimitPass() {
    let log: [String: JSONValue] = ["type": s("log"), "text": s(chars(1))]
    #expect(event(log, allowed: all.subtracting([.log])) == .failure(.notDeclared("log")))
    // Cubi's own first line is not something a service may send back.
    #expect(P.event(Data(P.hello().dropLast().utf8), allowed: all) == .failure(.unknownType("hello")))
    #expect(event(["text": s(chars(1))]) == .failure(.badField("type", "要是字串")))
    #expect(P.event(Data(P.hello().dropLast(2).utf8), allowed: all) == .failure(.notJSON))
    #expect(P.event(Data(PluginIO.encode(JSONValue.array([s("log")])).utf8), allowed: all) == .failure(.notJSON))

    // Exactly the limit passes; one byte more is dropped whole.
    let frame = line(["type": s("log"), "text": s("")]).count
    let atLimit = line(["type": s("state"), "data": .object(["type": s(chars(P.lineLimit - frame - 16))])])
    #expect(atLimit.count <= P.lineLimit)
    let padded = atLimit + Data(repeating: 0x20, count: P.lineLimit - atLimit.count)
    #expect(padded.count == P.lineLimit)
    #expect((try? P.event(padded, allowed: all).get()) != nil)
    #expect(P.event(padded + Data([0x20]), allowed: all) == .failure(.tooLong(P.lineLimit + 1)))
}

@Test func textIsPlainAndWithinItsLimit() {
    for (type, field, limit) in [("notice", "title", P.titleLimit), ("log", "text", P.logLimit)] {
        #expect(event(["type": s(type), field: s(chars(limit))]) == .success(type == "log" ? .log(chars(limit)) : .notice(title: chars(limit), body: nil, sound: nil)))
        #expect(event(["type": s(type), field: s(chars(limit + 1))]) == .failure(.badField(field, "最多 \(limit) 字")))
        #expect(event(["type": s(type), field: s("")]) == .failure(.badField(field, "要是非空字串")))
        #expect(event(["type": s(type)]) == .failure(.badField(field, "必填")))
    }
    #expect(event(["type": s("notice"), "title": s(chars(1)), "body": s(chars(P.bodyLimit + 1))]) == .failure(.badField("body", "最多 \(P.bodyLimit) 字")))
    // C0 (a newline), DEL and C1 are control characters.
    for scalar in [0x0a, 0x7f, 0x85] {
        let t = chars(1) + String(Character(Unicode.Scalar(UInt32(scalar))!))
        #expect(event(["type": s("notice"), "title": s(t)]) == .failure(.badField("title", forbidden)))
    }
}

private let forbidden = "不能有控制字元、換行或文字方向控制字元"

// F61-1 (review of batch 61): the scalars are Unicode's (U+2028 LINE SEPARATOR, U+202E
// RIGHT-TO-LEFT OVERRIDE, U+061C ARABIC LETTER MARK, U+200B ZERO WIDTH SPACE, U+00AD SOFT HYPHEN,
// U+3164 HANGUL FILLER, U+0301 COMBINING ACUTE ACCENT); the reviewer's probes found each passing.
@Test func textHasNoHiddenLineBreaksDirectionControlsOrBlanksAndBoundedScalars() {
    func title(_ t: String) -> Result<P.Event, P.Problem> { event(["type": s("notice"), "title": s(t)]) }
    let a = chars(1)
    for u: UInt32 in [0x2028, 0x2029, 0x200e, 0x200f, 0x202a, 0x202e, 0x2066, 0x2069, 0x061c] {
        let t = a + String(Character(Unicode.Scalar(u)!)) + a
        #expect(title(t) == .failure(.badField("title", forbidden)))
    }
    #expect(event(["type": s("present"), "id": n(0), "effect": s("shake"), "from": s("\u{202E}" + a)]) == .failure(.badField("from", forbidden)))
    for blank in ["\u{200B}", "   ", "\u{3000}", "\u{FEFF}\u{2060}", "\u{00AD}", "\u{3164}"] {
        #expect(title(blank) == .failure(.badField("title", "不能只有空白")))
    }
    // One character carrying combining marks: up to limit × 4 scalars.
    let mark = "\u{0301}"
    let atCap = a + String(repeating: mark, count: P.titleLimit * 4 - 1)
    #expect(title(atCap) == .success(.notice(title: atCap, body: nil, sound: nil)))
    #expect(title(atCap + mark) == .failure(.badField("title", "組合符號太多（最多 \(P.titleLimit * 4) 個 Unicode 字元）")))
    // Not every format character goes: an emoji family is joined by U+200D.
    for fine in ["👨‍👩‍👧", "🙂", "繁中", "👨‍👩‍👧 " + a] {
        #expect(title(fine) == .success(.notice(title: fine, body: nil, sound: nil)))
    }
}

// F61-2: the reviewer's input, a type with a newline and an ANSI escape.
@Test func anUnknownTypeIsQuotedSafelyForTheLog() {
    let type = "x\ny\u{1B}[31m"
    #expect(event(["type": s(type)]) == .failure(.unknownType("x\\u{a}y\\u{1b}[31m")))
    let msg = P.Problem.unknownType(P.quoted(type)).errorDescription!
    #expect(!msg.unicodeScalars.contains(where: P.isForbidden))
    // At most 40 scalars of it.
    let long = String(repeating: chars(1), count: 41)
    #expect(event(["type": s(long)]) == .failure(.unknownType(String(long.prefix(40)))))
}

@Test func namesIdsAndFlagsAreChecked() {
    let shake = "shake", knock = P.sounds.sorted()[0]
    // A sound that is not an effect, and an effect that is not a sound.
    let thud = P.sounds.subtracting(P.effects).sorted()[0]
    #expect(event(["type": s("present"), "id": n(0), "effect": s(thud), "from": s(knock)]) == .failure(.badField("effect", "只能是 \(P.effects.sorted().joined(separator: "、"))")))
    #expect(event(["type": s("notice"), "title": s(knock), "sound": s(shake)]) == .failure(.badField("sound", "只能是 \(P.sounds.sorted().joined(separator: "、"))")))
    for bad in [n(-1), n(0.5), n(1e300), s("0")] {
        #expect(event(["type": s("reply"), "id": bad, "ok": .bool(true)]) == .failure(.badField("id", "要是 0 以上的整數")))
    }
    #expect(event(["type": s("reply"), "id": n(0)]) == .failure(.badField("ok", "要是 true 或 false")))
    #expect(event(["type": s("reply"), "id": n(0), "ok": s("true")]) == .failure(.badField("ok", "要是 true 或 false")))
    #expect(event(["type": s("present"), "id": n(0), "effect": s(shake), "from": s(knock), "windowShaken": n(1)]) == .failure(.badField("windowShaken", "要是 true 或 false")))
    #expect(event(["type": s("state"), "data": .array([])]) == .failure(.badField("data", "要是物件")))
}

@Test func cubisLinesAreOneJSONObjectEachWithAFixedType() throws {
    #expect(P.hello() == "{\"protocol\":\(P.version),\"type\":\"hello\"}\n")
    #expect(P.call(id: 3, action: "send", args: nil) == "{\"action\":\"send\",\"id\":3,\"type\":\"call\"}\n")
    let args = try JSONDecoder().decode(JSONValue.self, from: Data(P.hello().utf8))
    let call = try JSONDecoder().decode(JSONValue.self, from: Data(P.call(id: 3, action: "send", args: args).utf8))
    #expect(call["args"] == args)
    #expect(P.presented(id: 4, failure: nil) == "{\"id\":4,\"ok\":true,\"type\":\"presented\"}\n")
    for f in P.presentFailures.sorted() {
        #expect(P.presented(id: 4, failure: f) == "{\"id\":4,\"ok\":false,\"reason\":\"\(f)\",\"type\":\"presented\"}\n")
    }
    // A newline inside a value is escaped, so every message stays one line.
    #expect(P.call(id: 0, action: "\n", args: nil).filter { $0 == "\n" }.count == 1)
}

@Test func theLineReaderSplitsAcrossChunksAndDropsOverlongLinesWhole() {
    let limit = P.titleLimit
    let a = Data(chars(limit).utf8), b = Data(chars(1).utf8), nl = Data([0x0a])
    var r = ServiceLineReader(limit: limit)
    // A line in two pieces, then two lines in one chunk.
    do { let got = r.push(a.prefix(3)); #expect(got == []) }
    do { let got = r.push(a.dropFirst(3) + nl + b + nl); #expect(got == [.line(a), .line(b)]) }
    // One byte over the limit, across chunks: reported once it ends, then reading goes on.
    do { let got = r.push(a); #expect(got == []) }
    do { let got = r.push(b); #expect(got == []) }
    do { let got = r.push(b + nl + b); #expect(got == [.dropped(limit + 2)]) }
    do { let got = r.push(nl); #expect(got == [.line(b)]) }
    // An empty line is a line (and an event parse will call it not JSON).
    do { let got = r.push(nl); #expect(got == [.line(Data())]) }
}

// F61-4: a service that prints its last line without a newline and exits.
@Test func finishGivesTheLastLineEvenWithoutANewline() {
    let last = Data(P.hello().dropLast().utf8)
    var r = ServiceLineReader()
    do { let got = r.push(last); #expect(got == []) }
    do { let got = r.finish(); #expect(got == [.line(last)]) }
    do { let got = r.finish(); #expect(got == []) }
    // Too long and unfinished: reported, not kept.
    var short = ServiceLineReader(limit: P.titleLimit)
    do { let got = short.push(Data(chars(P.titleLimit + 1).utf8)); #expect(got == []) }
    do { let got = short.finish(); #expect(got == [.dropped(P.titleLimit + 1)]) }
    // Nothing left: nothing.
    var empty = ServiceLineReader()
    do { let got = empty.push(Data(P.hello().utf8)); #expect(got == [.line(last)]) }
    do { let got = empty.finish(); #expect(got == []) }
}

// F65 (review of batch 65): the island names the plugin (its name is "LAN Nudge" in the author repo's
// cubi-plugin/lan-nudge/manifest.json), and one service gets one notice per noticeInterval.
@Test func aNoticeNamesItsPluginAndComesAtMostOncePerInterval() {
    let knock = P.sounds.sorted()[0], plugin = "LAN Nudge"
    // Two lines, whatever the service says: the second is the plugin's name, not something it wrote.
    #expect(P.noticeLines(title: knock, plugin: plugin) == [knock, plugin])

    var gate = ServiceRateLimit(count: 1, per: P.noticeInterval)
    let t0 = ContinuousClock.now
    do { let got = gate.allow(at: t0); #expect(got) }
    // As many more as the line limit lets through in that time: none of them.
    let tries = Int(P.noticeInterval.components.seconds) * P.linesPerSecond - 1
    let blocked = (1...tries).map { i in gate.allow(at: t0.advanced(by: P.noticeInterval / (tries + 1) * i)) }
    #expect(!blocked.contains(true))
    do { let got = gate.allow(at: t0.advanced(by: P.noticeInterval)); #expect(got) }
}

// F61-3: monotonic instants (ContinuousClock.now plus offsets): only the interval counts, so a
// wall clock set back cannot hold the output up.
@Test func theRateLimitSlidesOnMonotonicTime() {
    var limit = ServiceRateLimit(count: P.linesPerSecond, per: .seconds(1))
    let t0 = ContinuousClock.now
    for _ in 0..<P.linesPerSecond { let got = limit.allow(at: t0); #expect(got) }
    do { let got = limit.allow(at: t0); #expect(!got) }
    do { let got = limit.allow(at: t0.advanced(by: .milliseconds(500))); #expect(!got) }
    do { let got = limit.allow(at: t0.advanced(by: .seconds(1))); #expect(got) }
    var logs = ServiceRateLimit(count: P.logsPerMinute, per: .seconds(60))
    let taken = (0..<(P.logsPerMinute + 1)).map { _ in logs.allow(at: t0) }.filter { $0 }.count
    #expect(taken == P.logsPerMinute)
}

// From the panel: args[0] is the action, args[1] (optional) a JSON object as a string.
@Test func aPanelCallIsAnActionNameAndAtMostOneJSONObject() throws {
    let plain = try P.panelCall(["send"]).get()
    #expect(plain.action == "send" && plain.args == nil)
    let args = P.hello().dropLast()
    let withArgs = try P.panelCall(["send", String(args)]).get()
    #expect(withArgs.args == (try JSONDecoder().decode(JSONValue.self, from: Data(args.utf8))))
    // The line Cubi writes carries them as they came.
    #expect(P.call(id: 1, action: withArgs.action, args: withArgs.args) == P.call(id: 1, action: "send", args: withArgs.args))

    #expect(throws: P.Problem.self) { try P.panelCall([]).get() }
    #expect(throws: P.Problem.self) { try P.panelCall(["Send"]).get() }
    #expect(throws: P.Problem.self) { try P.panelCall(["send", "{}", "{}"]).get() }
    #expect(throws: P.Problem.self) { try P.panelCall(["send", "[]"]).get() }
    #expect(throws: P.Problem.self) { try P.panelCall(["send", "{"]).get() }
    // At the line limit as a string it passes; one byte over does not.
    let pad = P.lineLimit - #"{"a":""}"#.utf8.count
    #expect((try? P.panelCall(["send", #"{"a":""# + chars(pad) + #""}"#]).get()) != nil)
    #expect(throws: P.Problem.self) { try P.panelCall(["send", #"{"a":""# + chars(pad + 1) + #""}"#]).get() }
}
