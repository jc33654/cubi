import Foundation
import Observation

/// User settings for the inactivity clocks: minutes of silence before a robot sleeps, and hours
/// of sleep before its session moves to the 晚安 zone (nil: never). Fixed choices, so no odd
/// values get in; a saved value outside them falls back to the default.
@MainActor
@Observable
final class SleepTiming {
    static let sleepChoices = [5, 10, 20, 30, 60]
    static let restChoices: [Int?] = [1, 3, 6, 12, 24, nil]
    static let sleepKey = "sleepAfterMinutes"
    static let restKey = "restAfterHours"

    // Initialised in the declarations, not in `init`: an optional stored property starts as nil,
    // so assigning it in `init` counts as a change and would write the defaults back at launch.
    var sleepMinutes: Int = SleepTiming.savedSleepMinutes() {
        didSet { UserDefaults.standard.set(sleepMinutes, forKey: Self.sleepKey); onChange() }
    }
    /// nil: never. Saved as 0.
    var restHours: Int? = SleepTiming.savedRestHours() {
        didSet { UserDefaults.standard.set(restHours ?? 0, forKey: Self.restKey); onChange() }
    }
    @ObservationIgnored var onChange: () -> Void = {}

    private static func savedSleepMinutes() -> Int {
        let sleep = UserDefaults.standard.integer(forKey: sleepKey)
        return sleepChoices.contains(sleep) ? sleep : 10
    }

    private static func savedRestHours() -> Int? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: restKey) != nil else { return 12 }
        let rest = defaults.integer(forKey: restKey)
        return rest == 0 ? nil : (restChoices.contains(rest) ? rest : 12)
    }

    var sleepAfter: Double { Double(sleepMinutes) * 60 }
    var restAfter: Double { restHours.map { Double($0) * 3600 } ?? .infinity }

    static func restLabel(_ hours: Int?) -> String { hours.map { "\($0) 小時" } ?? "從不" }
}
