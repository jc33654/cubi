import AppKit

/// Built-in macOS sounds, no assets in the repo. Off switch in the menu.
///
/// The first NSSound ever played brings up the audio stack, which took ~2 s on the main thread
/// and delayed the card that triggered it. So the sounds are loaded and primed in the background
/// at launch, and `play` only ever touches ready instances.
@MainActor
enum Sounds {
    static let enabledKey = "soundsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    enum Cue: CaseIterable { case pending, allow, deny, answer, done }

    nonisolated private static func name(_ cue: Cue) -> String {
        switch cue {
        case .pending: return "Tink"
        case .allow, .answer: return "Pop"
        case .deny: return "Basso"
        case .done: return "Glass"
        }
    }

    nonisolated(unsafe) private static var cache: [String: NSSound] = [:]
    nonisolated(unsafe) private static var ready = false

    /// Loads every cue and plays one silently so the audio device is up before it matters.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            var loaded: [String: NSSound] = [:]
            for cue in Cue.allCases {
                let n = name(cue)
                if loaded[n] == nil, let s = NSSound(named: NSSound.Name(n)) { loaded[n] = s }
            }
            if let any = loaded.values.first {
                any.volume = 0
                any.play()
            }
            DispatchQueue.main.async {
                cache = loaded
                ready = true
            }
        }
    }

    static func play(_ cue: Cue) {
        guard enabled, ready, let sound = cache[name(cue)] else { return }
        sound.stop()
        sound.volume = 0.3
        sound.play()
    }
}
