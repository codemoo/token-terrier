import Foundation

/// Burn-rate readout produced by `BurnTracker` for inclusion in a snapshot.
public struct BurnSnapshot: Equatable, Sendable {
    public let ratePerMinute: Double
    public let state: BurnState
    public let todayTotalTokens: Int
    public let todaySessionsCount: Int
    public let hasObservedAnyEvent: Bool

    public init(
        ratePerMinute: Double,
        state: BurnState,
        todayTotalTokens: Int,
        todaySessionsCount: Int,
        hasObservedAnyEvent: Bool)
    {
        self.ratePerMinute = ratePerMinute
        self.state = state
        self.todayTotalTokens = todayTotalTokens
        self.todaySessionsCount = todaySessionsCount
        self.hasObservedAnyEvent = hasObservedAnyEvent
    }

    public static let zero = BurnSnapshot(
        ratePerMinute: 0,
        state: .idle,
        todayTotalTokens: 0,
        todaySessionsCount: 0,
        hasObservedAnyEvent: false)
}

/// Six-step character animation state derived from burn rate (tokens per minute).
///
/// Original Sapeet ranges (100/300/600/1000/2000) were calibrated for *output*
/// tokens. Our metric also includes Claude `cache_creation` and Codex
/// `reasoning` which inflate counts ~50×, so a normal Claude Code session was
/// flat-lining at `rocket`. Re-baselined on observed real usage to keep all
/// six states reachable:
///   idle <500 / walk 500–3k / jog 3k–12k / run 12k–40k / fly 40k–100k / rocket 100k+.
/// `BurnState.next(...)` applies ±20% hysteresis and a 5 s minimum dwell.
public enum BurnState: String, Codable, Sendable, CaseIterable {
    case idle
    case walk
    case jog
    case run
    case fly
    case rocket

    /// Upper threshold (tokens/min) at or above which the next state is entered when ascending.
    fileprivate static let upperEnter: [Double] = [500, 3_000, 12_000, 40_000, 100_000]

    /// Lower threshold (tokens/min) below which the previous state is entered when descending.
    /// 20% lower than `upperEnter` for hysteresis.
    fileprivate static let lowerExit: [Double] = [400, 2_400, 9_600, 32_000, 80_000]

    /// Index in the ordered ladder; useful for ladder math.
    fileprivate var index: Int {
        switch self {
        case .idle: return 0
        case .walk: return 1
        case .jog: return 2
        case .run: return 3
        case .fly: return 4
        case .rocket: return 5
        }
    }

    fileprivate static func at(_ index: Int) -> BurnState {
        BurnState.allCases[max(0, min(index, BurnState.allCases.count - 1))]
    }

    /// Returns the next state given the current value, current state, last transition timestamp,
    /// and current time. Honours ±20% hysteresis and a 5 s minimum dwell.
    public static func next(
        value: Double,
        current: BurnState,
        lastChange: Date,
        now: Date,
        minimumDwell: TimeInterval = 5)
        -> BurnState
    {
        let elapsed = now.timeIntervalSince(lastChange)
        // Negative `elapsed` means `lastChange` is in the future relative to `now`
        // (e.g. a test that picks an old fixed `now`). Treat that case as "outside the
        // dwell window" so callers get the natural state transition rather than being
        // pinned to the previous state.
        if elapsed >= 0 && elapsed < minimumDwell {
            return current
        }
        var idx = current.index
        while idx < upperEnter.count && value >= upperEnter[idx] {
            idx += 1
        }
        if idx > current.index {
            return at(idx)
        }
        while idx > 0 && value < lowerExit[idx - 1] {
            idx -= 1
        }
        return at(idx)
    }
}

/// Computes a smoothed tokens-per-minute burn rate from a stream of `TokenEvent`s.
///
/// Internally maintains a 60 s sliding-sum deque and an EWMA (τ ≈ 20 s). The reported
/// rate is `max(sliding, ewma)` which favours responsiveness during bursts while the
/// EWMA dampens single-spike noise. Per-day totals are reset at local midnight using
/// the configured `timeZone`.
public actor BurnTracker {
    private let provider: Provider
    private let timeZone: TimeZone
    private let windowSeconds: TimeInterval
    private let ewmaTimeConstant: TimeInterval

    /// (timestamp, tokens) within the sliding window.
    private var window: [(Date, Int)] = []
    private var ewma: Double = 0
    private var lastEwmaUpdate: Date?
    private var todayDay: Date?
    private var todayTotal: Int = 0
    private var todaySessions: Set<String> = []
    private var hasObserved: Bool = false

    private var currentState: BurnState = .idle
    private var lastStateChange: Date

    public init(
        provider: Provider,
        timeZone: TimeZone = .current,
        windowSeconds: TimeInterval = 60,
        ewmaTimeConstant: TimeInterval = 20,
        clock: Date = Date())
    {
        self.provider = provider
        self.timeZone = timeZone
        self.windowSeconds = windowSeconds
        self.ewmaTimeConstant = ewmaTimeConstant
        // Anchor the dwell origin in the past so the first observed event can
        // immediately transition out of the initial idle state.
        self.lastStateChange = clock.addingTimeInterval(-3_600)
    }

    /// Records a token event and returns the resulting snapshot.
    public func ingest(_ event: TokenEvent, now: Date = Date()) -> BurnSnapshot {
        rolloverIfNeeded(now: event.timestamp)
        hasObserved = true
        todayTotal += event.tokens
        todaySessions.insert(event.sessionKey)

        // sliding window
        window.append((event.timestamp, event.tokens))
        evictExpired(now: now)

        // EWMA
        updateEwmaForEvent(event: event, now: now)

        // state transition
        let value = currentValue(now: now)
        let newState = BurnState.next(
            value: value,
            current: currentState,
            lastChange: lastStateChange,
            now: now)
        if newState != currentState {
            currentState = newState
            lastStateChange = now
        }

        return makeSnapshot(now: now, value: value)
    }

    /// Returns the current snapshot without ingesting an event. Decays the EWMA in place.
    public func snapshot(now: Date = Date()) -> BurnSnapshot {
        rolloverIfNeeded(now: now)
        evictExpired(now: now)
        decayEwmaToNow(now: now)
        let value = currentValue(now: now)
        let newState = BurnState.next(
            value: value,
            current: currentState,
            lastChange: lastStateChange,
            now: now)
        if newState != currentState {
            currentState = newState
            lastStateChange = now
        }
        return makeSnapshot(now: now, value: value)
    }

    private func makeSnapshot(now: Date, value: Double) -> BurnSnapshot {
        BurnSnapshot(
            ratePerMinute: value,
            state: currentState,
            todayTotalTokens: todayTotal,
            todaySessionsCount: todaySessions.count,
            hasObservedAnyEvent: hasObserved)
    }

    private func currentValue(now: Date) -> Double {
        let slidingTokens = window.reduce(0) { $0 + $1.1 }
        // sum over last 60 s == tokens / minute when windowSeconds == 60
        let scale = 60.0 / windowSeconds
        let sliding = Double(slidingTokens) * scale
        return max(sliding, ewma)
    }

    private func evictExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        while let first = window.first, first.0 < cutoff {
            window.removeFirst()
        }
    }

    private func updateEwmaForEvent(event: TokenEvent, now: Date) {
        // Treat each event as "this many tokens within the sliding window" — i.e. the
        // single-event sliding-rate equivalent. This keeps the EWMA on the same scale
        // as `currentValue.sliding` (tokens/min) instead of exploding by 60×.
        let instant = Double(event.tokens) * 60.0 / windowSeconds
        if let last = lastEwmaUpdate {
            let dt = max(0.001, now.timeIntervalSince(last))
            let alpha = 1 - exp(-dt / ewmaTimeConstant)
            // First decay the previous EWMA to "now", then blend in instant.
            let decayed = ewma * exp(-dt / ewmaTimeConstant)
            ewma = decayed + alpha * (instant - decayed)
        } else {
            ewma = instant
        }
        lastEwmaUpdate = now
    }

    private func decayEwmaToNow(now: Date) {
        guard let last = lastEwmaUpdate else { return }
        let dt = max(0, now.timeIntervalSince(last))
        ewma = ewma * exp(-dt / ewmaTimeConstant)
        lastEwmaUpdate = now
    }

    private func rolloverIfNeeded(now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: now)
        if todayDay != day {
            todayDay = day
            todayTotal = 0
            todaySessions = []
        }
    }
}
