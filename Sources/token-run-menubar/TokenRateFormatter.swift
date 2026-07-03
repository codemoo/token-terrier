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
}
