import Foundation

enum TokenRate {
    static func perHourLabel(_ v: Double) -> String {
        let value = max(0, v)
        if value < 1000 {
            return "\(Int(value)) tok/h"
        } else if value < 1_000_000 {
            return String(format: "%.1fk tok/h", value / 1000)
        } else {
            return String(format: "%.1fM tok/h", value / 1_000_000)
        }
    }

    /// Bare k/M abbreviation for a cumulative token count, no unit suffix
    /// (callers add their own label, e.g. "누적 1.2M").
    static func countLabel(_ v: Int64) -> String {
        let value = Double(max(0, v))
        if value < 1000 {
            return "\(Int64(value))"
        } else if value < 1_000_000 {
            return String(format: "%.1fk", value / 1000)
        } else {
            return String(format: "%.1fM", value / 1_000_000)
        }
    }
}
