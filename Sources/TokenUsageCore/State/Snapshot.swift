import Foundation

/// Represents a single quota window in normalized form.
public struct QuotaWindow: Codable, Equatable, Sendable {
    public let label: String
    public let scope: String
    public let usedPct: Double
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case label
        case scope
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
    }

    public init(label: String, scope: String, usedPct: Double, resetsAt: String?) {
        self.label = label
        self.scope = scope
        self.usedPct = usedPct
        self.resetsAt = resetsAt
    }
}

/// Represents a normalized rolling quota window.
public struct RollingWindow: Codable, Equatable, Sendable {
    public let usedPct: Double
    public let remainingSeconds: Int
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case usedPct = "used_pct"
        case remainingSeconds = "remaining_seconds"
        case resetsAt = "resets_at"
    }

    public init(usedPct: Double, remainingSeconds: Int, resetsAt: String?) {
        self.usedPct = usedPct
        self.remainingSeconds = remainingSeconds
        self.resetsAt = resetsAt
    }

    public static let empty = RollingWindow(usedPct: 0, remainingSeconds: 0, resetsAt: nil)
}

/// Represents credit balance information when a provider exposes it.
public struct Credits: Codable, Equatable, Sendable {
    public let remaining: Double
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case remaining
        case updatedAt = "updated_at"
    }

    public init(remaining: Double, updatedAt: String?) {
        self.remaining = remaining
        self.updatedAt = updatedAt
    }
}

/// Carries provider-specific metadata that is not part of the common quota windows.
public struct SnapshotExtras: Codable, Equatable, Sendable {
    public let loginMethod: String?
    public let accountEmail: String?
    public let rateLimitTier: String?
    public let extraRateWindows: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case loginMethod = "login_method"
        case accountEmail = "account_email"
        case rateLimitTier = "rate_limit_tier"
        case extraRateWindows = "extra_rate_windows"
    }

    public init(
        loginMethod: String?,
        accountEmail: String?,
        rateLimitTier: String?,
        extraRateWindows: [JSONValue])
    {
        self.loginMethod = loginMethod
        self.accountEmail = accountEmail
        self.rateLimitTier = rateLimitTier
        self.extraRateWindows = extraRateWindows
    }

    public static let empty = SnapshotExtras(
        loginMethod: nil,
        accountEmail: nil,
        rateLimitTier: nil,
        extraRateWindows: [])
}

/// One quota window for a single claude-swap account.
public struct AccountWindow: Codable, Equatable, Sendable {
    public let usedPct: Double
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
    }

    public init(usedPct: Double, resetsAt: String?) {
        self.usedPct = usedPct
        self.resetsAt = resetsAt
    }
}

/// One claude-swap-managed Claude account's usage (menu-bar per-account rows).
public struct AccountUsage: Codable, Equatable, Sendable {
    public let number: Int
    public let email: String
    public let active: Bool
    public let status: String
    public let fiveHour: AccountWindow?
    public let sevenDay: AccountWindow?

    enum CodingKeys: String, CodingKey {
        case number
        case email
        case active
        case status
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    public init(number: Int, email: String, active: Bool, status: String,
                fiveHour: AccountWindow?, sevenDay: AccountWindow?) {
        self.number = number
        self.email = email
        self.active = active
        self.status = status
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// Captures the fetch status embedded in every snapshot.
public struct SnapshotStatus: Codable, Equatable, Sendable {
    public let state: ProviderState
    public let dataSource: SnapshotDataSource
    public let stale: Bool

    enum CodingKeys: String, CodingKey {
        case state
        case dataSource = "data_source"
        case stale
    }

    public init(state: ProviderState, dataSource: SnapshotDataSource = .apiOnly, stale: Bool) {
        self.state = state
        self.dataSource = dataSource
        self.stale = stale
    }
}

/// Represents the final SSE snapshot schema.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let schema: Int
    public let seq: Int
    public let generatedAtUTC: String
    public let producerID: String
    public let producerTimeZone: String
    public let provider: Provider
    public let burnRatePerMinute: Double
    public let burnState: String
    public let todayTotalTokens: Int
    public let todaySessions: Int
    public let rolling5h: RollingWindow
    public let weekly: RollingWindow
    public let quotaWindows: [QuotaWindow]
    public let credits: Credits?
    public let extras: SnapshotExtras
    public let status: SnapshotStatus
    public let accounts: [AccountUsage]?
    public let accountsUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case seq
        case generatedAtUTC = "generated_at_utc"
        case producerID = "producer_id"
        case producerTimeZone = "producer_tz"
        case provider
        case burnRatePerMinute = "burn_rate_per_min"
        case burnState = "burn_state"
        case todayTotalTokens = "today_total_tokens"
        case todaySessions = "today_sessions"
        case rolling5h = "rolling_5h"
        case weekly
        case quotaWindows = "quota_windows"
        case credits
        case extras
        case status
        case accounts
        case accountsUpdatedAt = "accounts_updated_at"
    }

    public init(
        schema: Int = 1,
        seq: Int,
        generatedAtUTC: String,
        producerID: String,
        producerTimeZone: String,
        provider: Provider,
        burnRatePerMinute: Double = 0,
        burnState: String = "idle",
        todayTotalTokens: Int = 0,
        todaySessions: Int = 0,
        rolling5h: RollingWindow,
        weekly: RollingWindow,
        quotaWindows: [QuotaWindow],
        credits: Credits?,
        extras: SnapshotExtras,
        status: SnapshotStatus,
        accounts: [AccountUsage]? = nil,
        accountsUpdatedAt: String? = nil)
    {
        self.schema = schema
        self.seq = seq
        self.generatedAtUTC = generatedAtUTC
        self.producerID = producerID
        self.producerTimeZone = producerTimeZone
        self.provider = provider
        self.burnRatePerMinute = burnRatePerMinute
        self.burnState = burnState
        self.todayTotalTokens = todayTotalTokens
        self.todaySessions = todaySessions
        self.rolling5h = rolling5h
        self.weekly = weekly
        self.quotaWindows = quotaWindows
        self.credits = credits
        self.extras = extras
        self.status = status
        self.accounts = accounts
        self.accountsUpdatedAt = accountsUpdatedAt
    }

    /// Builds a degraded snapshot that preserves the final schema.
    public static func degraded(
        provider: Provider,
        seq: Int,
        producer: ProducerInfo,
        now: Date,
        state: ProviderState)
        -> UsageSnapshot
    {
        UsageSnapshot(
            seq: seq,
            generatedAtUTC: SnapshotDateFormatter.string(from: now),
            producerID: producer.id,
            producerTimeZone: producer.timeZone,
            provider: provider,
            rolling5h: .empty,
            weekly: .empty,
            quotaWindows: [],
            credits: nil,
            extras: .empty,
            status: SnapshotStatus(state: state, stale: true))
    }
}
