import Foundation

/// Formats dates for the public snapshot schema.
public enum SnapshotDateFormatter {
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// Returns an ISO8601 UTC string.
    public static func string(from date: Date) -> String {
        makeFormatter(fractional: true).string(from: date)
    }

    /// Parses ISO8601 strings with or without fractional seconds.
    public static func date(from string: String) -> Date? {
        let fractional = makeFormatter(fractional: true)
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = makeFormatter(fractional: false)
        return plain.date(from: string)
    }

    /// Returns non-negative whole seconds until a reset date.
    public static func remainingSeconds(until reset: Date?, now: Date) -> Int {
        guard let reset else { return 0 }
        return max(0, Int(reset.timeIntervalSince(now).rounded(.down)))
    }
}
