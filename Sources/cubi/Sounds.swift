import AppKit

/// Built-in macOS sounds, no assets in the repo. Off switch in the menu.
@MainActor
enum Sounds {
    static let enabledKey = "soundsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    enum Cue { case pending, allow, deny, answer, done }

    private static func name(_ cue: Cue) -> String {
        switch cue {
        case .pending: return "Tink"
        case .allow, .answer: return "Pop"
        case .deny: return "Basso"
        case .done: return "Glass"
        }
    }

    static func play(_ cue: Cue) {
        guard enabled, let sound = NSSound(named: NSSound.Name(name(cue))) else { return }
        sound.volume = 0.3
        sound.play()
    }
}
