import SwiftUI
import TokenUsageCore

struct MenuBarContentView: View {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider == .claude ? "Claude Code" : "Codex")
                    .font(.subheadline.bold())
                Spacer()
                stateChip(status: status)
            }

            if let snapshot = status.snapshot {
                if let degraded = degradedMessage(for: snapshot.status.state, provider: provider) {
                    Text(degraded)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
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
            } else {
                Text(emptyStateText(for: status, provider: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
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
    private static func resetText(at resetsAt: Date, now: Date) -> String {
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

    private static func remainingHuman(seconds: Int) -> String {
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
