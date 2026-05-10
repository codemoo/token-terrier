import Foundation

/// Raw Claude usage response returned by the OAuth usage endpoint.
public struct ClaudeUsageResponse: Decodable, Equatable, Sendable {
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    public let sevenDaySonnet: ClaudeUsageWindow?
    public let sevenDayOpus: ClaudeUsageWindow?
    public let extraRateWindows: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraRateWindows = "extra_rate_windows"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fiveHour = try container.decodeIfPresent(ClaudeUsageWindow.self, forKey: .fiveHour)
        self.sevenDay = try container.decodeIfPresent(ClaudeUsageWindow.self, forKey: .sevenDay)
        self.sevenDaySonnet = try container.decodeIfPresent(ClaudeUsageWindow.self, forKey: .sevenDaySonnet)
        self.sevenDayOpus = try container.decodeIfPresent(ClaudeUsageWindow.self, forKey: .sevenDayOpus)
        self.extraRateWindows = (try? container.decodeIfPresent([JSONValue].self, forKey: .extraRateWindows)) ?? []
    }
}

/// Raw Claude quota window with percent utilization.
public struct ClaudeUsageWindow: Decodable, Equatable, Sendable {
    public let utilization: Double
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Raw Codex usage response accepting both snake_case and camelCase API shapes.
public struct CodexUsageResponse: Decodable, Equatable, Sendable {
    public let primary: CodexUsageWindow?
    public let secondary: CodexUsageWindow?
    public let tertiary: CodexUsageWindow?
    public let credits: CodexCredits?
    public let loginMethod: String?
    public let accountEmail: String?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case primary
        case secondary
        case tertiary
        case credits
        case loginMethod
        case accountEmail
    }

    enum RateLimitKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
        case tertiaryWindow = "tertiary_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rateLimit = try? container.nestedContainer(keyedBy: RateLimitKeys.self, forKey: .rateLimit)
        self.primary = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .primary)
            ?? rateLimit?.decodeLossy(CodexUsageWindow.self, forKey: .primaryWindow)
        self.secondary = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .secondary)
            ?? rateLimit?.decodeLossy(CodexUsageWindow.self, forKey: .secondaryWindow)
        self.tertiary = try container.decodeIfPresent(CodexUsageWindow.self, forKey: .tertiary)
            ?? rateLimit?.decodeLossy(CodexUsageWindow.self, forKey: .tertiaryWindow)
        self.credits = try container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        self.loginMethod = try container.decodeIfPresent(String.self, forKey: .loginMethod)
            ?? container.decodeLossy(String.self, forKey: .planType)
        self.accountEmail = try container.decodeIfPresent(String.self, forKey: .accountEmail)
    }
}

/// Raw Codex quota window with percent utilization.
public struct CodexUsageWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let windowSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case usedPercentSnake = "used_percent"
        case resetsAt
        case resetAt = "reset_at"
        case windowMinutes
        case limitWindowSeconds = "limit_window_seconds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = container.decodeLossy(Double.self, forKey: .usedPercent)
            ?? container.decodeLossy(Double.self, forKey: .usedPercentSnake)
        if let resetsAt = container.decodeLossy(String.self, forKey: .resetsAt) {
            self.resetsAt = SnapshotDateFormatter.date(from: resetsAt)
        } else if let resetAt = container.decodeLossy(Int.self, forKey: .resetAt) {
            self.resetsAt = Date(timeIntervalSince1970: TimeInterval(resetAt))
        } else if let resetAt = container.decodeLossy(Double.self, forKey: .resetAt) {
            self.resetsAt = Date(timeIntervalSince1970: resetAt)
        } else {
            self.resetsAt = nil
        }
        if let seconds = container.decodeLossy(Int.self, forKey: .limitWindowSeconds) {
            self.windowSeconds = seconds
        } else if let minutes = container.decodeLossy(Int.self, forKey: .windowMinutes) {
            self.windowSeconds = minutes * 60
        } else {
            self.windowSeconds = nil
        }
    }
}

/// Raw Codex credits response accepting observed API variants.
public struct CodexCredits: Decodable, Equatable, Sendable {
    public let remaining: Double?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case remaining
        case updatedAt
        case balance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.remaining = container.decodeLossy(Double.self, forKey: .remaining)
            ?? container.decodeLossy(Double.self, forKey: .balance)
        if let value = container.decodeLossy(String.self, forKey: .updatedAt) {
            self.updatedAt = SnapshotDateFormatter.date(from: value)
        } else {
            self.updatedAt = nil
        }
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeLossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? self.decodeIfPresent(type, forKey: key)
    }
}
