import Foundation

/// Text for the usage strip. Reset times follow the same rule as statusline.sh: an absolute
/// Taipei time, `HH:mm` within 24 h, `M/d HH:mm` beyond.
public enum UsageFormat {
    public static let timeZone = TimeZone(identifier: "Asia/Taipei")!

    public static func resetLabel(resetsAt: Double?, now: Date = Date()) -> String? {
        guard let epoch = resetsAt else { return nil }
        let date = Date(timeIntervalSince1970: epoch)
        let diff = date.timeIntervalSince(now)
        if diff <= 0 { return "now" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = diff > 86_400 ? "M/d HH:mm" : "HH:mm"
        return f.string(from: date)
    }

    /// Green under 50, amber under 80, red from 80: the thresholds statusline.sh uses.
    public enum Level: Sendable { case ok, warn, hot }
    public static func level(_ percent: Double) -> Level {
        percent < 50 ? .ok : (percent < 80 ? .warn : .hot)
    }
}
