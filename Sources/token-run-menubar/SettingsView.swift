import AppKit
import SwiftUI
import TokenUsageCore

struct SettingsView: View {
    @Bindable var appState: AppState
    @Bindable var updater: UpdaterController
    @Bindable var loginItem: LaunchAtLoginController

    var body: some View {
        TabView {
            ConnectionTab(settings: appState.settings, status: appState.status)
                .tabItem { Label("연결", systemImage: "network") }
            TokensTab(settings: appState.settings)
                .tabItem { Label("인증", systemImage: "key.horizontal") }
            AppearanceTab(settings: appState.settings, loginItem: loginItem)
                .tabItem { Label("외관", systemImage: "paintbrush") }
            UpdatesTab(updater: updater)
                .tabItem { Label("업데이트", systemImage: "arrow.down.circle") }
            AboutTab()
                .tabItem { Label("정보", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 480)
        .scenePadding(.horizontal)
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @Bindable var settings: AppSettings
    @Bindable var loginItem: LaunchAtLoginController

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 12) {
                        Slider(
                            value: $settings.menuBarBedlHeight,
                            in: AppSettings.menuBarBedlHeightRange,
                            step: 1)
                        Text("\(Int(settings.menuBarBedlHeight)) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    Label("메뉴바 베들 크기", systemImage: "pawprint")
                }

                LabeledContent {
                    HStack(spacing: 12) {
                        Slider(
                            value: $settings.menuBarBedlSpeed,
                            in: AppSettings.menuBarBedlSpeedRange,
                            step: 0.05)
                        Text(String(format: "%.2fx", settings.menuBarBedlSpeed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                } label: {
                    Label("루프 기준 속도", systemImage: "speedometer")
                }
            } header: {
                Text("메뉴바")
            } footer: {
                Text("크기 기본값 \(Int(AppSettings.menuBarBedlHeightDefault)) pt, 속도 기본값 \(String(format: "%.2fx", AppSettings.menuBarBedlSpeedDefault)) 입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $loginItem.isEnabled) {
                    Label("로그인 시 자동 시작", systemImage: "power")
                }
            } header: {
                Text("실행")
            } footer: {
                Text("System Settings → General → Login Items 에서도 같은 토글을 볼 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Connection

private struct ConnectionTab: View {
    @Bindable var settings: AppSettings
    let status: StatusStore

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.claudeConnectionMode) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Label("Claude", systemImage: "sparkle")
                }
                Picker(selection: $settings.codexConnectionMode) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: {
                Text("연결 모드")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(modeHint(settings.claudeConnectionMode, prefix: "Claude"))
                    Text(modeHint(settings.codexConnectionMode, prefix: "Codex"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Endpoint") {
                LabeledContent {
                    TextField("", text: $settings.remoteURL,
                              prompt: Text("https://your-token-server.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                } label: {
                    Label("원격", systemImage: "globe")
                }

                LabeledContent {
                    TextField("", text: $settings.loopbackURL,
                              prompt: Text("http://127.0.0.1:18910"))
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                } label: {
                    Label("로컬", systemImage: "macbook")
                }
            }

            Section("실시간 상태") {
                providerStatusRow(label: "Claude Code", status: status.claude)
                providerStatusRow(label: "Codex", status: status.codex)
            }
        }
        .formStyle(.grouped)
    }

    private func providerStatusRow(label: String, status: ProviderStatus) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor(status.state))
                .frame(width: 9, height: 9)
                .shadow(color: stateColor(status.state).opacity(0.4), radius: 2)
            Text(label)
            Spacer()
            Text(stateLabel(status))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func stateColor(_ state: ProviderConnectionState) -> Color {
        switch state {
        case .idle: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .stale: return .orange
        case .offline: return .red
        }
    }

    private func stateLabel(_ status: ProviderStatus) -> String {
        switch status.state {
        case .idle: return "—"
        case .connecting: return "연결 중…"
        case .connected:
            let source = status.activeSource ?? "ok"
            return "연결됨 · \(source)"
        case .stale: return "stale (>60s)"
        case .offline: return "오프라인"
        }
    }

    private func modeHint(_ mode: ConnectionMode, prefix: String) -> String {
        switch mode {
        case .auto:
            return "\(prefix) · 자동 (loopback → 원격 폴백)"
        case .remote:
            return "\(prefix) · 원격 서버만"
        case .loopback:
            return "\(prefix) · 로컬 daemon 만 (127.0.0.1)"
        case .localDirect:
            return "\(prefix) · 로컬 OAuth 직접 read (daemon 없음)"
        }
    }
}

// MARK: - Tokens

private struct TokensTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    SecureField("", text: $settings.claudeBearer)
                        .textFieldStyle(.roundedBorder)
                } label: {
                    Label("Claude Code", systemImage: "sparkle")
                }

                LabeledContent {
                    SecureField("", text: $settings.codexBearer)
                        .textFieldStyle(.roundedBorder)
                } label: {
                    Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: {
                Text("Bearer 토큰")
            } footer: {
                Text("Producer Mac 에서는 자동 시드되며, 다른 디바이스에서는 직접 붙여넣으세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

private struct UpdatesTab: View {
    @Bindable var updater: UpdaterController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                    Label("새 버전 자동 확인", systemImage: "arrow.triangle.2.circlepath")
                }
                Toggle(isOn: $updater.automaticallyDownloadsUpdates) {
                    Label("백그라운드에서 자동 다운로드", systemImage: "arrow.down.circle")
                }
                .disabled(!updater.automaticallyChecksForUpdates)

                Picker(selection: $updater.updateCheckIntervalHours) {
                    Text("1시간").tag(1.0)
                    Text("4시간").tag(4.0)
                    Text("하루").tag(24.0)
                    Text("일주일").tag(168.0)
                } label: {
                    Label("확인 주기", systemImage: "timer")
                }
                .disabled(!updater.automaticallyChecksForUpdates)
            } header: {
                Text("자동 업데이트")
            } footer: {
                Text("자동 확인을 끄면 \"지금 확인\" 버튼으로만 업데이트를 받습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("수동 확인") {
                HStack {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("지금 확인…", systemImage: "magnifyingglass")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.canCheckForUpdates)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        if let date = updater.lastUpdateCheckDate {
                            Text("마지막 확인")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("아직 확인한 적 없음")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("현재 버전") {
                LabeledContent("Token Terrier") {
                    Text(currentVersion)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.secondary.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)

            VStack(spacing: 4) {
                Text("Token Terrier")
                    .font(.title2.bold())
                Text("Claude · Codex 사용량 메뉴바 모니터")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(currentVersion)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Spacer()

            Text("© 2026 Hwanmoo Yong")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "버전 \(short)"
    }
}
