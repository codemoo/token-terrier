import SwiftUI
import TokenUsageCore

struct MenuBarContentView: View {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings

    /// Which provider's per-account detail panel is expanded to the right.
    /// `nil` = collapsed (single 320pt column). Both providers can open a
    /// panel once their backend ships `accounts[]`; Codex's card still shows
    /// its aggregate top-line summary (never averaged) rather than switching
    /// to Claude's per-account average bars.
    @State private var selectedProvider: Provider?

    var body: some View {
        ZStack(alignment: .trailing) {
            // Master card column (always visible)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                providerCard(.claude)
                Divider()
                providerCard(.codex)
                Divider()
                footer
            }
            .frame(width: 320)

            // Detail panel overlays as a floating panel on the right
            if let provider = selectedProvider,
               let accounts = appState.status[provider].snapshot?.accounts,
               !accounts.isEmpty {
                ZStack(alignment: .topLeading) {
                    // Dark overlay behind the panel
                    Color.black.opacity(0.12)

                    AccountDetailPanel(
                        provider: provider,
                        accounts: accounts,
                        activeBurnPerHour: activeBurnPerHour(provider),
                        accountsUpdatedAt: appState.status[provider].snapshot?.accountsUpdatedAt,
                        onClose: { selectedProvider = nil })
                        .frame(width: 300)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedProvider)
        .onDisappear { selectedProvider = nil }
    }

    /// Tokens/hour for the active account, derived from the aggregate burn rate.
    /// Only Claude exposes a live burn rate in Phase 1; Codex returns nil until
    /// Phase 2 wires per-account rates.
    private func activeBurnPerHour(_ provider: Provider) -> Double? {
        guard provider == .claude,
              let snapshot = appState.status[provider].snapshot else { return nil }
        return snapshot.burnRatePerMinute * 60
    }

    /// A card can be tapped to open its detail panel only when it actually has
    /// per-account rows to show. Phase 2: both providers, once their daemon
    /// backend ships `accounts[]` (Codex via the codex-lb refresher).
    private func isSelectable(_ provider: Provider) -> Bool {
        return appState.status[provider].snapshot?.accounts?.isEmpty == false
    }

    private var header: some View {
        HStack(spacing: 9) {
            BedlAvatar()

            Text("Token Terrier")
                .font(.headline)
            Spacer()
            // C/X badges show each provider's connection mode at a glance.
            Text(modeBadge)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var modeBadge: String {
        let c = appState.settings.claudeConnectionMode.shortLabel
        let x = appState.settings.codexConnectionMode.shortLabel
        return c == x ? c : "C:\(c) · X:\(x)"
    }

    @ViewBuilder
    private func providerCard(_ provider: Provider) -> some View {
        let status = appState.status[provider]
        let selectable = isSelectable(provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider == .claude ? "Claude Code" : "Codex")
                    .font(.subheadline.bold())
                Spacer()
                stateChip(status: status)
            }

            if let snapshot = status.snapshot {
                let accounts = snapshot.accounts ?? []
                if provider == .claude, !accounts.isEmpty {
                    // Claude master card = per-account averages + affordance to
                    // expand the detail panel. A degraded state (auth/network)
                    // becomes a small inline note instead of hiding the whole
                    // card, because claude-swap still ships per-account rows in
                    // that case.
                    accountsSummary(snapshot: snapshot, accounts: accounts, provider: provider)
                } else if let degraded = degradedMessage(for: snapshot.status.state, provider: provider) {
                    Text(degraded)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Codex keeps its aggregate top-line summary (never
                    // averaged) even when per-account rows exist; the accounts
                    // are only surfaced via the detail panel's `▸`.
                    aggregateMetrics(snapshot: snapshot)
                    if provider != .claude, !accounts.isEmpty {
                        accountsAffordance(count: accounts.count, updatedAt: snapshot.accountsUpdatedAt, provider: provider)
                    }
                }
            } else {
                Text(emptyStateText(for: status, provider: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectable else { return }
            selectedProvider = (selectedProvider == provider ? nil : provider)
        }
    }

    /// The original aggregate top-line (burn + 5h/weekly + credits). Still used
    /// by Codex and by Claude when no per-account rows are available.
    @ViewBuilder
    private func aggregateMetrics(snapshot: UsageSnapshot) -> some View {
        metricsRow(snapshot: snapshot)
        quotaRow(label: "5h", window: snapshot.rolling5h)
        quotaRow(label: "주간", window: snapshot.weekly)
        if let credits = snapshot.credits {
            HStack {
                Text("Credits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f", credits.remaining))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    /// Claude master card: two average usage bars across all "ok" accounts, an
    /// "N 계정 평균" caption, and a chevron that rotates when its panel is open.
    @ViewBuilder
    private func accountsSummary(snapshot: UsageSnapshot, accounts: [AccountUsage], provider: Provider) -> some View {
        if let degraded = degradedMessage(for: snapshot.status.state, provider: provider) {
            Text(degraded)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        averageBar(label: "5h", value: AccountAverages.fiveHour(accounts))
        averageBar(label: "주간", value: AccountAverages.sevenDay(accounts))
        accountsAffordance(count: accounts.count, updatedAt: snapshot.accountsUpdatedAt, provider: provider)
    }

    /// "N개 계정 · 갱신 X분 전" caption + chevron affordance that opens the
    /// detail panel. Shared by the Claude average card and the Codex
    /// aggregate card (Codex keeps its top-line but still gets this row once
    /// it has per-account data to show).
    @ViewBuilder
    private func accountsAffordance(count: Int, updatedAt: String?, provider: Provider) -> some View {
        HStack {
            Text("\(count)개 계정")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let updatedCaption = Self.freshnessCaption(updatedAt, now: .now) {
                Text("· \(updatedCaption)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(selectedProvider == provider ? 90 : 0))
        }
    }

    /// Formats an ISO8601 timestamp as a short relative-past caption, e.g.
    /// "갱신 3분 전". Returns nil when the string is missing or unparsable so
    /// callers can simply omit the caption.
    static func freshnessCaption(_ isoString: String?, now: Date) -> String? {
        guard let isoString, let date = SnapshotDateFormatter.date(from: isoString) else { return nil }
        return "갱신 \(relativePast(date, now: now))"
    }

    /// "방금" / "N분 전" / "N시간 전" / "N일 전" relative-past label.
    static func relativePast(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "방금" }
        if seconds < 3_600 { return "\(seconds / 60)분 전" }
        if seconds < 86_400 { return "\(seconds / 3_600)시간 전" }
        return "\(seconds / 86_400)일 전"
    }

    @ViewBuilder
    private func averageBar(label: String, value: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            if let value {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Text("데이터 없음")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metricsRow(snapshot: UsageSnapshot) -> some View {
        HStack {
            Label(snapshot.burnState, systemImage: "bolt.fill")
                .font(.caption.bold())
                .foregroundStyle(.tint)
            Spacer()
            Text("\(Int(snapshot.burnRatePerMinute)) tok/min")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func quotaRow(label: String, window: RollingWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                ProgressView(value: window.usedPct)
                    .progressViewStyle(.linear)
                Text("\(Int(window.usedPct * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            // Reset 시각 + "남음" 표시. 5시간 윈도우는 분 단위로 줄어드니까
            // 30초 주기 TimelineView로 자동 갱신해 "남은 시간"이 stale로
            // 보이지 않게 한다. weekly는 보통 일 단위라 갱신 효과가 미미하지만
            // 두 row 모두 동일 path로 처리해 코드 분기 없앰.
            if let resetsAtString = window.resetsAt,
               let resetsAt = SnapshotDateFormatter.date(from: resetsAtString) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.resetText(at: resetsAt, now: context.date))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    /// "오늘 18:51 갱신 · 3시간 12분 남음" 같은 한 줄을 만든다.
    /// `resetsAt`이 이미 지났거나 음수면 그냥 빈 문자열을 반환하지 않고
    /// "갱신 대기" 메시지를 띄워 사용자에게 무언가가 stale 상태임을 알린다.
    static func resetText(at resetsAt: Date, now: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")

        let absolute: String
        if calendar.isDateInToday(resetsAt) {
            formatter.dateFormat = "HH:mm"
            absolute = "오늘 \(formatter.string(from: resetsAt))"
        } else if calendar.isDateInTomorrow(resetsAt) {
            formatter.dateFormat = "HH:mm"
            absolute = "내일 \(formatter.string(from: resetsAt))"
        } else {
            formatter.dateFormat = "M/d(E) HH:mm"
            absolute = formatter.string(from: resetsAt)
        }

        let secondsRemaining = Int(resetsAt.timeIntervalSince(now))
        if secondsRemaining <= 0 {
            return "\(absolute) 갱신 (지남)"
        }
        return "\(absolute) 갱신 · \(remainingHuman(seconds: secondsRemaining)) 남음"
    }

    static func remainingHuman(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)초" }
        if seconds < 3_600 { return "\(seconds / 60)분" }
        if seconds < 86_400 {
            let h = seconds / 3_600
            let m = (seconds % 3_600) / 60
            return m > 0 ? "\(h)시간 \(m)분" : "\(h)시간"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        return hours > 0 ? "\(days)일 \(hours)시간" : "\(days)일"
    }

    @ViewBuilder
    private func stateChip(status: ProviderStatus) -> some View {
        let (label, color) = chipDescription(status: status)
        Text(label)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func chipDescription(status: ProviderStatus) -> (String, Color) {
        switch status.state {
        case .idle: return ("idle", .gray)
        case .connecting: return ("connect…", .yellow)
        case .connected: return ((status.activeSource ?? "ok"), .green)
        case .stale: return ("stale", .orange)
        case .offline: return ("offline", .red)
        }
    }

    /// Returns a human-readable message when the snapshot is present but
    /// degraded (auth expired, network error, etc.). `nil` means the snapshot
    /// is OK and quota/burn metrics should render normally.
    private func degradedMessage(for state: ProviderState, provider: Provider) -> String? {
        switch state {
        case .ok:
            return nil
        case .refreshing:
            return "OAuth 토큰 갱신 중…"
        case .authExpired:
            return provider == .claude
                ? "Claude Code 자격증명 없음 또는 만료 — `claude login` 으로 재로그인."
                : "OAuth 만료 — 재로그인 필요."
        case .codexLoggedOut:
            return "Codex 미로그인 — `codex login` 실행 후 다시 시도."
        case .networkError:
            return "API 일시 장애 — 다음 주기에 재시도합니다."
        case .quotaEndpointChanged:
            return "공급자가 응답 형식을 바꿨습니다 — 앱 업데이트 필요."
        }
    }

    private func emptyStateText(for status: ProviderStatus, provider: Provider) -> String {
        switch status.state {
        case .connecting:
            return appState.settings.mode(for: provider) == .localDirect
                ? "로컬 자격증명 읽는 중…"
                : "연결 중…"
        case .offline: return "오프라인 — 재연결 중"
        default: return "데이터 없음"
        }
    }

    private var footer: some View {
        HStack {
            Button {
                // Activate before opening Settings so the new window gets key focus
                // (otherwise its text fields swallow keystrokes). openSettings is the
                // macOS 14+ SwiftUI environment action — works for menu-bar-only apps
                // where sendAction("showSettingsWindow:") fails because there is no
                // standard responder chain.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("설정…", systemImage: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("종료").font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

}

private struct BedlAvatar: View {
    var body: some View {
        Image(nsImage: BedlIcon.image)
            .resizable()
            .scaledToFill()
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(.secondary.opacity(0.22), lineWidth: 0.5)
            }
            .accessibilityLabel("밥풀이")
    }
}
