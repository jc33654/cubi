import Foundation
import Testing
@testable import CubiKit

/// Batch 37: where a session may open, checked on real folders (a scratch home under the temp
/// directory), because the rule compares what folders are, not how they are written.
private struct ScratchHome {
    let root: String
    let home: String

    init() throws {
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appendingPathComponent("guard-" + UUID().uuidString).path
        try fm.createDirectory(atPath: made, withIntermediateDirectories: true)
        root = DirectoryGuard.realPath(made) ?? made          // /private/var/…, the name the data volume knows
        home = root + "/home"
        for dir in [".ssh/keys", ".config/atlassian", "Library/Keychains", "Documents/proj", "Documents/.sshconfig-notes"] {
            try fm.createDirectory(atPath: home + "/" + dir, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: root + "/to-ssh", withDestinationPath: home + "/.ssh")
        try fm.createSymbolicLink(atPath: root + "/to-proj", withDestinationPath: home + "/Documents/proj")
        try fm.createSymbolicLink(atPath: home + "/Documents/proj/up", withDestinationPath: home)
    }

    func refusal(_ path: String) -> DirectoryGuard.Refusal? { DirectoryGuard.refusal(path, homes: [home]) }
    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
}

@Test func aProjectFolderIsFineAndNamesThatOnlyLookAlikeToo() throws {
    let s = try ScratchHome()
    defer { s.cleanUp() }
    #expect(s.refusal(s.home + "/Documents/proj") == nil)
    #expect(s.refusal(s.home + "/Documents/.sshconfig-notes") == nil)
    #expect(s.refusal(s.root + "/to-proj") == nil)                                   // a link to a fine folder is fine
    #expect(s.refusal(s.home + "/Documents/proj/../proj") == nil)
}

@Test func theHomeAndEverythingAboveItAreRefused() throws {
    let s = try ScratchHome()
    defer { s.cleanUp() }
    for path in [s.home, s.home + "/", s.root, "/", s.home + "/Documents/proj/../..", s.home + "/Documents/proj/up"] {
        #expect(s.refusal(path) == .guarded((path as NSString).expandingTildeInPath), "\(path)")
    }
}

@Test func keysAndWhatIsInsideThemAreRefusedHoweverWritten() throws {
    let s = try ScratchHome()
    defer { s.cleanUp() }
    for path in [s.home + "/.ssh", s.home + "/.ssh/keys", s.home + "/.config/atlassian", s.home + "/Library/Keychains", s.home + "/.config", s.home + "/Library",
                 s.root + "/to-ssh", s.root + "/to-ssh/keys"] {
        #expect(s.refusal(path) == .guarded(path), "\(path)")
    }
    // A case-insensitive volume (the default) finds .SSH as .ssh: the same folder, refused.
    let upper = s.home + "/.SSH"
    #expect(FileManager.default.fileExists(atPath: upper), "this volume is case-sensitive: the case check did not run")
    #expect(s.refusal(upper) == .guarded(upper))
    // The data volume's other name for the same folders.
    let firm = DirectoryGuard.firmlinkRoot + s.home + "/.ssh"
    #expect(FileManager.default.fileExists(atPath: firm), "no firmlink path here: that check did not run")
    #expect(s.refusal(firm) == .guarded(firm))
    #expect(s.refusal(DirectoryGuard.firmlinkRoot + s.home) == .guarded(DirectoryGuard.firmlinkRoot + s.home))
}

@Test func aFolderThatIsNotThereIsSaidSo() throws {
    let s = try ScratchHome()
    defer { s.cleanUp() }
    #expect(s.refusal(s.home + "/nowhere") == .missing(s.home + "/nowhere"))
    #expect(DirectoryGuard.Refusal.missing("/x").message == "找不到資料夾 /x")
    #expect(DirectoryGuard.Refusal.guarded("/x").message.hasPrefix("不能在 /x 開 session"))
}
