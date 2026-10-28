// Stable per-session colours. Swift's hashValue is seeded per launch, so the palette index is
// derived from FNV-1a instead: the same session id gets the same colour after a restart.

public struct RGB: Sendable, Equatable, Hashable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    public init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    /// Mixes towards a neutral grey of the same luminance; 1 = unchanged, 0 = fully grey.
    public func saturated(_ amount: Double) -> RGB {
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return RGB(r: lum + (r - lum) * amount, g: lum + (g - lum) * amount, b: lum + (b - lum) * amount)
    }

    /// Lightens (positive) or darkens (negative) by mixing with white or black.
    public func adjusted(by amount: Double) -> RGB {
        let target = amount >= 0 ? 1.0 : 0.0
        let a = min(1, abs(amount))
        return RGB(r: r + (target - r) * a, g: g + (target - g) * a, b: b + (target - b) * a)
    }
}

public enum SessionPalette {
    /// Ten colours that stay distinguishable at 16 pt on black (a 12-colour set had near-twins).
    public static let colors: [RGB] = [
        RGB(hex: 0x4F9CF9), // blue
        RGB(hex: 0xF5A524), // amber
        RGB(hex: 0x3DD68C), // green
        RGB(hex: 0xF06292), // pink
        RGB(hex: 0xA78BFA), // violet
        RGB(hex: 0x2DD4BF), // teal
        RGB(hex: 0xEF4444), // red
        RGB(hex: 0xFACC15), // yellow
        RGB(hex: 0xA3E635), // lime
        RGB(hex: 0xE2E8F0), // silver
    ]

    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Palette index for a session id, skipping indices already in use by other live sessions.
    public static func index(for sessionID: String, taken: Set<Int> = []) -> Int {
        let count = colors.count
        var index = Int(fnv1a(sessionID) % UInt64(count))
        if taken.count >= count { return index }
        while taken.contains(index) { index = (index + 1) % count }
        return index
    }

    public static func color(for sessionID: String, taken: Set<Int> = []) -> RGB {
        colors[index(for: sessionID, taken: taken)]
    }
}
