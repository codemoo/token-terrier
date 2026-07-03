# Per-Account Menu Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메뉴바에서 Claude 기본뷰=cswap 계정 평균 + 클릭시 오른쪽 마스터-디테일 패널로 계정별(+시간당 토큰), Codex 는 codex-lb 대시보드 인증으로 계정별을 같은 방식으로 추가한다.

**Architecture:** Phase 1 은 앱 전용(이미 내려오는 claude-swap `accounts[]` + 기존 burn 만 사용, 신규 secret 없음). Phase 2 는 외부 Python refresher 가 codex-lb 에 로그인해 계정별을 파일로 쓰고(비번 refresher-only), 데몬은 파일만 읽어 `accounts[]` 로 붙이며(standalone+local-fs), 앱이 codex 계정별을 렌더한다.

**Tech Stack:** Swift/SwiftUI(macOS 14+, SwiftPM), Go 1.23(`server-go`, module `github.com/codemoo/token-terrier/server-go`), Python 3(refresher), launchd.

## Global Constraints

- Go: `cd server-go && go test ./... -race` 항상 green. gofmt.
- Swift: `swift build -c release` 성공. macOS `.v14` 타겟.
- **wire 변경은 additive omitempty 만** — 기존 Claude/no-account 스냅샷 JSON byte-identity 유지.
- **Secret:** codex-lb 대시보드 비번은 **refresher 의 0600 env 파일에만**. git 커밋·로그·stdout·plist body 금지. 데몬 env 아님.
- **데몬은 codex-lb 에 로그인하지 않음** — 파일만 read (standalone + local-filesystem, AGENTS.md:104).
- **머신특정 launchd plist 커밋 금지** (installer 가 생성). 기본 remote URL 빈 값 유지.
- UI 카피는 한국어.
- 커밋 메시지 말미:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01MX2xTUfZAzwEr2tyxLtaKX
  ```

## File Structure

**Phase 1 (Swift 앱):**
- Modify `Sources/TokenUsageCore/State/Snapshot.swift` — `AccountUsage` 에 `tokensPerHour`/`totalTokens` 추가, `accountStatusLabel` 유지.
- Create `Sources/TokenUsageCore/State/AccountAverages.swift` — 계정 평균 계산 순수 함수(테스트 대상).
- Create `Sources/token-run-menubar/TokenRateFormatter.swift` — tokens/hour → `k/M` 축약.
- Modify `Sources/token-run-menubar/MenuBarContentView.swift` — 마스터-디테일 셸, 요약 카드=평균, 클릭 selection.
- Create `Sources/token-run-menubar/AccountDetailPanel.swift` — 우측 계정별 패널(폴리시).
- Test: `Tests/TokenUsageCoreTests/AccountAveragesTests.swift`, `Tests/.../TokenRateFormatterTests.swift`.

**Phase 2 (데몬 + refresher + Codex UI):**
- Modify `server-go/internal/wire/types.go` — `AccountUsage.TokensPerHour *float64`, `TotalTokens *int64` (omitempty).
- Create `server-go/internal/codexaccounts/reader.go` — codex 계정 파일 reader(claudeswap.Reader 미러) + status 정규화 + 매핑.
- Create `server-go/internal/codexaccounts/reader_test.go`.
- Modify `server-go/internal/state/usage_state.go:128` — `decorateAccounts` provider 가드 완화.
- Modify `server-go/internal/state/accounts_test.go:46` — `TestCodexNeverDecorated` 교체.
- Modify `server-go/cmd/daemon/main.go` — codex accounts provider 배선.
- Create `scripts/codex-lb-accounts-refresh.py` — 로그인+계정+델타+derived JSON.
- Create `scripts/install-codex-lb-accounts-refresh.sh` — launchd installer(0600 env source).
- Test: `scripts/test_codex_lb_refresh.py` (델타/검증 유닛).
- Modify `Sources/token-run-menubar/*` — codex `▸` 활성, 계정 행 tokens/hr+total, alias 라벨; `accountStatusLabel` codex 케이스.

---

## PHASE 1 — Claude 평균 + 마스터-디테일 + 활성계정 tokens/hr (앱 전용)

### Task 1: `AccountUsage` 모델에 토큰 필드 추가

**Files:**
- Modify: `Sources/TokenUsageCore/State/Snapshot.swift` (AccountUsage struct, ~line 112-138)
- Test: `Tests/TokenUsageCoreTests/AccountUsageDecodeTests.swift` (create)

**Interfaces:**
- Produces: `AccountUsage.tokensPerHour: Double?`, `AccountUsage.totalTokens: Int64?` (both `Decodable`, keys `tokens_per_hour`, `total_tokens`).

- [ ] **Step 1: 실패 테스트** — JSON 에 `tokens_per_hour`/`total_tokens` 있고 없는 두 케이스 디코딩.
```swift
func test_accountUsage_decodesTokenFields() throws {
    let json = #"{"number":1,"email":"a@x","active":true,"status":"ok","tokens_per_hour":1234.5,"total_tokens":99}"#
    let a = try JSONDecoder().decode(AccountUsage.self, from: Data(json.utf8))
    XCTAssertEqual(a.tokensPerHour, 1234.5)
    XCTAssertEqual(a.totalTokens, 99)
}
func test_accountUsage_tokenFieldsOptionalMissing() throws {
    let json = #"{"number":1,"email":"a@x","active":true,"status":"ok"}"#
    let a = try JSONDecoder().decode(AccountUsage.self, from: Data(json.utf8))
    XCTAssertNil(a.tokensPerHour); XCTAssertNil(a.totalTokens)
}
```
- [ ] **Step 2: 실패 확인** — `swift test --filter AccountUsageDecode` → FAIL(멤버 없음).
- [ ] **Step 3: 구현** — `AccountUsage` 에 `public let tokensPerHour: Double?` / `public let totalTokens: Int64?` 추가, `CodingKeys` 에 `case tokensPerHour = "tokens_per_hour"`, `case totalTokens = "total_tokens"`. 기존 필드/이니셜라이저 보존(다른 필드는 그대로).
- [ ] **Step 4: 통과 확인** — `swift test --filter AccountUsageDecode` → PASS.
- [ ] **Step 5: 커밋** — `feat(app): AccountUsage 에 tokens_per_hour/total_tokens 옵셔널 필드`.

### Task 2: 계정 평균 계산 순수 함수

**Files:**
- Create: `Sources/TokenUsageCore/State/AccountAverages.swift`
- Test: `Tests/TokenUsageCoreTests/AccountAveragesTests.swift`

**Interfaces:**
- Consumes: `[AccountUsage]`, `AccountWindow.usedPct: Double`, `AccountUsage.status`, `.fiveHour`, `.sevenDay`.
- Produces: `enum AccountAverages { static func fiveHour(_ accounts: [AccountUsage]) -> Double?; static func sevenDay(_ accounts: [AccountUsage]) -> Double? }` — status=="ok" & 해당 윈도우 non-nil 계정의 `usedPct` 산술평균, 자격 0 → `nil`.

- [ ] **Step 1: 실패 테스트**
```swift
func test_average_ignoresNonOkAndNilWindow() {
    let accts = [
        mkAccount(status:"ok", five:0.4, seven:0.6),
        mkAccount(status:"ok", five:0.2, seven:nil),
        mkAccount(status:"token_expired", five:0.9, seven:0.9), // 제외
    ]
    XCTAssertEqual(AccountAverages.fiveHour(accts)!, 0.3, accuracy: 1e-9) // (0.4+0.2)/2
    XCTAssertEqual(AccountAverages.sevenDay(accts)!, 0.6, accuracy: 1e-9) // 0.6 하나만
}
func test_average_nilWhenNoEligible() {
    XCTAssertNil(AccountAverages.fiveHour([mkAccount(status:"token_expired", five:0.5, seven:0.5)]))
    XCTAssertNil(AccountAverages.fiveHour([]))
}
```
(테스트 파일에 `mkAccount(status:five:seven:)` 헬퍼 작성 — `AccountWindow(usedPct:resetsAt:)`, nil 이면 윈도우 nil.)
- [ ] **Step 2: 실패 확인** — `swift test --filter AccountAverages` → FAIL.
- [ ] **Step 3: 구현**
```swift
public enum AccountAverages {
    public static func fiveHour(_ a: [AccountUsage]) -> Double? { mean(a, \.fiveHour) }
    public static func sevenDay(_ a: [AccountUsage]) -> Double? { mean(a, \.sevenDay) }
    private static func mean(_ a: [AccountUsage], _ kp: KeyPath<AccountUsage, AccountWindow?>) -> Double? {
        let vals = a.filter { $0.status == "ok" }.compactMap { $0[keyPath: kp]?.usedPct }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }
}
```
- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: 커밋** — `feat(app): 계정 평균 계산 순수 함수(ok+non-nil, 없으면 nil)`.

### Task 3: tokens/hour 축약 포매터

**Files:**
- Create: `Sources/token-run-menubar/TokenRateFormatter.swift`
- Test: `Tests/token-run-menubarTests/TokenRateFormatterTests.swift` (없으면 타겟 확인 후 배치)

**Interfaces:**
- Produces: `enum TokenRate { static func perHourLabel(_ v: Double) -> String }` → `"920 tok/h"`, `"1.2k tok/h"`, `"3.4M tok/h"`.

- [ ] **Step 1: 실패 테스트**
```swift
func test_perHourLabel() {
    XCTAssertEqual(TokenRate.perHourLabel(920), "920 tok/h")
    XCTAssertEqual(TokenRate.perHourLabel(1234), "1.2k tok/h")
    XCTAssertEqual(TokenRate.perHourLabel(3_400_000), "3.4M tok/h")
    XCTAssertEqual(TokenRate.perHourLabel(0), "0 tok/h")
}
```
- [ ] **Step 2: 실패 확인** → FAIL.
- [ ] **Step 3: 구현** — `< 1000` 정수, `< 1e6` `%.1fk`, else `%.1fM`. 소수 `.0` 는 그대로 둔다(테스트값 기준). 음수는 `max(0, v)`.
- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: 커밋** — `feat(app): tokens/hour k/M 축약 포매터`.

### Task 4: 마스터-디테일 셸 + 요약 카드(평균) 리팩터

**Files:**
- Modify: `Sources/token-run-menubar/MenuBarContentView.swift`
- Create: `Sources/token-run-menubar/AccountDetailPanel.swift`

**Interfaces:**
- Consumes: `AppState`, `Provider`, `UsageSnapshot.accounts`, `AccountAverages`, `TokenRate`.
- Produces: `MenuBarContentView` 에 `@State private var selectedProvider: Provider?`; `AccountDetailPanel(provider:accounts:activeBurnPerHour:)` 뷰.

- [ ] **Step 1: 요약 카드 리팩터(수동 확인 기반)** — `providerCard(_:)` 를 다음으로 구조 변경:
  - `snapshot.accounts` 가 non-empty 이고 `provider == .claude` → top-line(5h/weekly) 대신 **평균 막대 2개**(`AccountAverages.fiveHour/sevenDay`, 각각 nil 이면 "데이터 없음" 소자) + "N 계정" 캡션 + `▸`(chevron) 버튼. `degradedMessage` 는 카드 전체를 가리지 않고 작은 인라인 노트로.
  - accounts 비었으면 기존 렌더 유지.
  - Codex 는 이 태스크에서 기존 aggregate 유지(변경 없음), `▸` 는 Phase 2 에서.
  - 카드 탭 = `selectedProvider = (selectedProvider == provider ? nil : provider)`; `.buttonStyle(.plain)` + `.contentShape(Rectangle())`.
- [ ] **Step 2: 마스터-디테일 HStack** — `body` 의 `VStack{...}.frame(width:320)` 을:
```swift
HStack(spacing: 0) {
    VStack(alignment:.leading, spacing:0) { header; Divider(); providerCard(.claude); Divider(); providerCard(.codex); Divider(); footer }
        .frame(width: 320)
    if let p = selectedProvider, let acc = appState.status[p].snapshot?.accounts, !acc.isEmpty {
        Divider()
        AccountDetailPanel(provider: p, accounts: acc, activeBurnPerHour: activeBurnPerHour(p))
            .frame(width: 300)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
.animation(.easeInOut(duration: 0.18), value: selectedProvider)
.clipped()
.onDisappear { selectedProvider = nil }
```
  `activeBurnPerHour(_:) -> Double?` = `provider==.claude` 이고 snapshot 있으면 `snapshot.burnRatePerMinute * 60`, 아니면 nil.
- [ ] **Step 3: `AccountDetailPanel.swift` 작성** — 헤더(provider 이름 + 닫기 `xmark`) + accounts `ForEach(id:.number)` 로 **폴리시된 계정 행**: 활성 `●`(largecircle.fill.circle) + email/라벨 + 우측 tokens/hr 배지(활성계정은 `activeBurnPerHour`, 아니면 `account.tokensPerHour` 있으면 그것) + 5h/7d 미니 진행바 + 리셋(기존 `resetText` 재사용). 로딩/빈 상태 텍스트.
- [ ] **Step 4: 빌드 + 수동 확인** — `swift build -c release` 성공. 앱 실행(로컬), Claude 카드에 평균+`▸`, 클릭시 우측 패널 슬라이드, 계정 행/배지 표시.
- [ ] **Step 5: 커밋** — `feat(app): Claude 마스터-디테일 셸 + 평균 요약 카드 + 계정 패널`.

### Task 5: `.window` 수평 리사이즈 실기 검증 + 폴백 결정

**Files:** (검증만; 폴백 시 Modify `MenuBarContentView.swift`)

- [ ] **Step 1: 실기 flicker 검증** — 맥에서 앱 실행, `▸` 반복 토글하며 창 리사이즈 깜빡임/클리핑/blank-gap 관찰(macOS 14/15).
- [ ] **Step 2: 판정** — 깜빡임 심하면 → **수직 disclosure 폴백**: HStack 우측 패널 대신 좌측 카드 아래로 `DisclosureGroup`/조건부 VStack 확장(폭 320 고정). 기능/컴포넌트(`AccountDetailPanel` 내용) 재사용.
- [ ] **Step 3: 커밋** — 수평 유지면 no-op 기록, 폴백이면 `fix(app): .window 잰크로 계정뷰 수직 disclosure 폴백`.

### Task 6: Phase 1 통합/폴리시 + Swift 유닛 그린

**Files:** Modify `MenuBarContentView.swift`, `AccountDetailPanel.swift`

- [ ] **Step 1** — 다크/라이트, 진행바 색(여유 green계열/임박 orange·red 임계), 접근성 라벨, 간격/타이포 마감(§UI 폴리시).
- [ ] **Step 2** — `swift test` 전체 green (Task 1-3 유닛).
- [ ] **Step 3: 커밋** — `style(app): 계정 뷰 폴리시(색/간격/접근성)`.

---

## PHASE 2 — Codex per-account + tokens/hr (검증된 Phase 1 이후)

### Task 7: wire 에 토큰 필드(Go)

**Files:**
- Modify: `server-go/internal/wire/types.go` (AccountUsage ~line 72-79)
- Test: `server-go/internal/wire/types_test.go` (byte-identity)

**Interfaces:**
- Produces: `AccountUsage.TokensPerHour *float64 json:"tokens_per_hour,omitempty"`, `TotalTokens *int64 json:"total_tokens,omitempty"`.

- [ ] **Step 1: 실패 테스트** — nil 이면 JSON 에 키 없음(byte-identity), 값 있으면 포함.
```go
func TestAccountUsage_TokenFieldsOmitempty(t *testing.T) {
    b,_ := json.Marshal(AccountUsage{Number:1, Email:"a@x", Active:true, Status:"ok"})
    if strings.Contains(string(b), "tokens_per_hour") || strings.Contains(string(b),"total_tokens") {
        t.Fatalf("nil 필드가 새어나옴: %s", b)
    }
    tph:=1.5; tt:=int64(9)
    b2,_:=json.Marshal(AccountUsage{Number:1,Email:"a@x",Active:true,Status:"ok",TokensPerHour:&tph,TotalTokens:&tt})
    if !strings.Contains(string(b2),`"tokens_per_hour":1.5`) || !strings.Contains(string(b2),`"total_tokens":9`) {
        t.Fatalf("값 필드 누락: %s", b2)
    }
}
```
- [ ] **Step 2: 실패 확인** — `go test ./internal/wire/ -run TokenFields` → FAIL.
- [ ] **Step 3: 구현** — 필드 2개 추가(포인터+omitempty).
- [ ] **Step 4: 통과 확인** → PASS. `go test ./... -race` green.
- [ ] **Step 5: 커밋** — `feat(server): wire.AccountUsage 에 tokens_per_hour/total_tokens omitempty`.

### Task 8: codex 계정 파일 reader(Go)

**Files:**
- Create: `server-go/internal/codexaccounts/reader.go`
- Create: `server-go/internal/codexaccounts/reader_test.go`

**Interfaces:**
- Consumes: derived JSON `{schemaVersion:1, accountsUpdatedAt, accounts:[{number,accountId,email,alias,displayName,status,fiveHourPct,sevenDayPct,resetAtPrimary,resetAtSecondary,totalTokens,tokensPerHour}]}`.
- Produces: `codexaccounts.NewReader(path string, logger *slog.Logger) *Reader` implementing `state.AccountsProvider` (`Accounts() ([]wire.AccountUsage, *string)`). status `active→ok`; label = alias||displayName||email → `Email` 필드에 표시라벨 넣지 말고 alias 는 별도? (v1: `Email` 에 email, 앱이 alias 우선표시하려면 alias 도 필요 → **매핑: `Email`=email, 그리고 alias 를 위해 `Status` 재활용 금지**. 단순화: v1 은 `Email`=`alias||displayName||email` 로 표시라벨 통일. 아래 테스트 기준.)

- [ ] **Step 1: 실패 테스트** — 파싱/매핑/정규화.
```go
func TestReader_MapsAndNormalizes(t *testing.T) {
    js := `{"schemaVersion":1,"accountsUpdatedAt":"2026-07-03T13:00:00Z","accounts":[
      {"number":1,"accountId":"aid1","email":"a@x","alias":"Work","status":"active","fiveHourPct":10,"sevenDayPct":92,"resetAtPrimary":"2026-07-03T15:00:00Z","resetAtSecondary":"2026-07-07T02:00:00Z","totalTokens":123,"tokensPerHour":45.6},
      {"number":2,"accountId":"aid2","email":"b@x","alias":"","status":"paused","fiveHourPct":null,"sevenDayPct":0}]}`
    // write to temp file, NewReader, Accounts()
    accts, updated := readerFromString(t, js).Accounts()
    if *updated != "2026-07-03T13:00:00Z" {...}
    if accts[0].Status != "ok" {...}                 // active→ok
    if accts[0].Email != "Work" {...}                // 표시라벨 alias 우선
    if math.Abs(accts[0].FiveHour.UsedPct-0.10)>1e-9 {...}  // 10% remaining? NO — refresher 가 이미 pct(used)로 내려줌: 아래 주석 참고
    if *accts[0].TokensPerHour != 45.6 || *accts[0].TotalTokens != 123 {...}
    if accts[1].Status != "paused" {...}             // pass-through
    if accts[1].FiveHour != nil {...}                // null 윈도우
}
```
  **주의(used vs remaining):** refresher(§Task 12)가 codex-lb `primaryRemainingPercent` 를 **used pct(0..1)** 로 이미 변환해 `fiveHourPct`(0..1) 로 내려준다. reader 는 그대로 `AccountWindow.UsedPct` 에 넣는다(재변환 금지). 테스트값도 used 기준으로 맞춘다.
- [ ] **Step 2: 실패 확인** → FAIL.
- [ ] **Step 3: 구현** — `internal/claudeswap/reader.go` 패턴 복제(mtime 캐시 + 2s throttle, schemaVersion==1 guard, ENOENT→dormant, keep-last-good on transient stat error). 매핑: `Number`=number(없으면 accountId 안정정렬 index), `Email`=`firstNonEmpty(alias, displayName, email)`, `Active`=status=="active", `Status`=normalize(active→ok), `FiveHour`=fiveHourPct nil?nil:`&AccountWindow{UsedPct:fiveHourPct, ResetsAt:resetAtPrimary}`, `SevenDay` 동일, `TokensPerHour`/`TotalTokens` 포인터 그대로.
- [ ] **Step 4: 통과 확인** → PASS. `-race` green.
- [ ] **Step 5: 커밋** — `feat(server): codex 계정 파일 reader(status 정규화·매핑·mtime 캐시)`.

### Task 9: `decorateAccounts` provider 가드 완화 + 테스트 교체

**Files:**
- Modify: `server-go/internal/state/usage_state.go:128`
- Modify: `server-go/internal/state/accounts_test.go:46` (`TestCodexNeverDecorated`)

**Interfaces:**
- Consumes: `state.AccountsProvider`(기존). **불변식:** accounts provider 는 State.provider 와 매칭되게 배선.

- [ ] **Step 1: 테스트 교체(실패)** — `TestCodexNeverDecorated` 를 `TestCodexDecoratedWhenProviderSet` 로: codex State 에 codex reader 붙이면 accounts 채워지고, 안 붙이면 nil.
- [ ] **Step 2: 실패 확인** → FAIL(현재 가드가 codex 를 항상 skip).
- [ ] **Step 3: 구현** — `decorateAccounts` 의 `if snap.Provider != wire.ProviderClaude { return snap }` **제거**. (락 규율 유지: `s.mu` 로 `s.accounts` 만 읽고 unlock 후 `ap.Accounts()`.) 주석에 "provider-매칭 reader 전제" 명시.
- [ ] **Step 4: 통과 확인** → PASS. `go test ./... -race` green.
- [ ] **Step 5: 커밋** — `feat(server): decorateAccounts provider-무관화(codex 포함) + 테스트 교체`.

### Task 10: 데몬 배선(codex accounts provider)

**Files:**
- Modify: `server-go/cmd/daemon/main.go` (codexState 배선부, ~line 92-100)

- [ ] **Step 1: 구현** — claude-swap 배선 대칭으로:
```go
if os.Getenv("TOKEN_USAGE_DISABLE_CODEX_ACCOUNTS") != "1" {
    p := strings.TrimSpace(os.Getenv("TOKEN_USAGE_CODEX_ACCOUNTS"))
    if p == "" { p = filepath.Join(home, ".config", "token-usage", "codex-lb-accounts.json") }
    codexState.SetAccountsProvider(codexaccounts.NewReader(p, logger))
}
```
  import 추가.
- [ ] **Step 2: 빌드** — `go build ./...` 성공. (파일 없으면 reader dormant → codex accounts nil, 회귀 없음.)
- [ ] **Step 3: 커밋** — `feat(server): codex accounts provider 배선(env-gate, 기본 경로)`.

### Task 11: Python refresher — 델타 계산 유닛(로그인/네트워크 없이)

**Files:**
- Create: `scripts/codex_lb_refresh_lib.py` (순수 함수: 매핑+델타+검증)
- Create: `scripts/test_codex_lb_refresh.py`

**Interfaces:**
- Produces:
  - `to_used_pct(remaining_percent) -> float|None` = `None if remaining is None else max(0.0,min(1.0,1-remaining/100))`.
  - `tokens_per_hour(prev, now) -> float|None` prev/now = `{"totalTokens":int,"ts":epoch}`; 첫샘플/음수델타/Δt<=0 → None; else `(Δtok)/(Δt/3600)`.
  - `build_derived(accounts_json, prev_samples, now_ts) -> (derived_dict, new_samples)` — /api/accounts body → derived shape(§spec), accountId 안정정렬 number, alias||displayName||email, used pct 변환, tokensPerHour 델타.
  - `validate_accounts_payload(obj) -> bool` — top-level `accounts` 가 list.

- [ ] **Step 1: 실패 테스트**
```python
def test_to_used_pct():
    assert to_used_pct(100)==0.0 and to_used_pct(0)==1.0 and to_used_pct(None) is None
def test_tokens_per_hour():
    assert tokens_per_hour(None, {"totalTokens":100,"ts":0}) is None      # 첫샘플
    assert tokens_per_hour({"totalTokens":100,"ts":0},{"totalTokens":100,"ts":0}) is None  # Δt<=0
    assert tokens_per_hour({"totalTokens":100,"ts":0},{"totalTokens":50,"ts":3600}) is None # 리셋(음수)
    assert tokens_per_hour({"totalTokens":100,"ts":0},{"totalTokens":700,"ts":3600})==600.0
def test_validate_rejects_401_body():
    assert validate_accounts_payload({"detail":"unauthorized"}) is False
    assert validate_accounts_payload({"accounts":[]}) is True
def test_build_derived_sorts_and_maps():
    body={"accounts":[{"accountId":"b","email":"b@x","alias":"","displayName":"","status":"paused","usage":{"primaryRemainingPercent":100,"secondaryRemainingPercent":0},"resetAtPrimary":"...","resetAtSecondary":"...","requestUsage":{"totalTokens":10}},
                      {"accountId":"a","email":"a@x","alias":"Work","status":"active","usage":{"primaryRemainingPercent":90,"secondaryRemainingPercent":8},"requestUsage":{"totalTokens":700}}]}
    prev={"a":{"totalTokens":100,"ts":0}}
    d,new=build_derived(body, prev, now_ts=3600)
    assert d["schemaVersion"]==1
    assert [x["accountId"] for x in d["accounts"]]==["a","b"]   # 안정정렬
    assert d["accounts"][0]["status"]=="active" and d["accounts"][0]["fiveHourPct"]==round(0.1,6)
    assert d["accounts"][0]["tokensPerHour"]==600.0            # (700-100)/1h
    assert new["a"]["totalTokens"]==700
```
- [ ] **Step 2: 실패 확인** — `python3 scripts/test_codex_lb_refresh.py` → FAIL.
- [ ] **Step 3: 구현** — `codex_lb_refresh_lib.py` 순수 함수 작성(위 계약). 부동소수 반올림 `round(x,6)`.
- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: 커밋** — `feat(scripts): codex-lb refresher 순수 로직(델타·매핑·검증) + 테스트`.

### Task 12: Python refresher — 실행 스크립트(로그인→/api/accounts→atomic write)

**Files:**
- Create: `scripts/codex-lb-accounts-refresh.py`

**Interfaces:**
- Consumes env: `CODEX_LB_DASHBOARD_PASSWORD`(필수), `CODEX_LB_URL`(기본 `http://127.0.0.1:2455`), 출력 `TOKEN_USAGE_CODEX_ACCOUNTS`(기본 `~/.config/token-usage/codex-lb-accounts.json`), 샘플 사이드카 `~/.config/token-usage/codex-lb-samples.json`.
- 라이브러리: `codex_lb_refresh_lib`.

- [ ] **Step 1: 구현(비번 없으면 즉시 종료)** — `urllib` 로:
  1. 비번 env 없으면 exit 0(기능 dormant), 로그 "password not set".
  2. `POST {URL}/api/dashboard-auth/password/login` json `{"password":...}`, `http.cookiejar` 로 `codex_lb_dashboard_session` 획득. 실패(비200) → **backoff 파일**(마지막 실패 ts) 확인해 rate-limit 회피, last-good 유지, exit 1(로그에 비번/쿠키 값 절대 미출력).
  3. `GET {URL}/api/accounts`(쿠키) → body. `validate_accounts_payload` 실패 → last-good 유지, exit 1.
  4. 사이드카 로드 → `build_derived(body, prev, now_ts=time.time())` → derived + new_samples.
  5. mkdir-lock single-flight, derived 를 mktemp→chmod600→os.replace 로 출력 파일 원자 교체, 사이드카도 원자 교체.
- [ ] **Step 2: 라이브 스모크(수동)** — `CODEX_LB_DASHBOARD_PASSWORD=… python3 scripts/codex-lb-accounts-refresh.py` → 출력 파일 생성, `accounts` 배열·필드 확인(비번/쿠키 미노출). 2회 실행시 tokensPerHour 채워지는지.
- [ ] **Step 3: 커밋** — `feat(scripts): codex-lb 계정 refresher 실행 스크립트(fresh-login·atomic·backoff)`.

### Task 13: launchd installer(0600 env source)

**Files:**
- Create: `scripts/install-codex-lb-accounts-refresh.sh`

- [ ] **Step 1: 구현** — `scripts/install-claude-swap-refresh.sh` 미러:
  - env 파일 `~/.config/token-usage/codex-lb-refresh.env`(0600) 생성/확인(사용자가 `CODEX_LB_DASHBOARD_PASSWORD=` 채우게 안내; 값 파일에만).
  - LaunchAgent plist `~/Library/LaunchAgents/ai.openclaw.token-usage-codex-lb-refresh.plist` 생성: `ProgramArguments` = `/bin/sh -lc 'set -a; . ~/.config/token-usage/codex-lb-refresh.env; set +a; exec python3 <repo>/scripts/codex-lb-accounts-refresh.py'`, `StartInterval 300`, 로그 경로. **plist body 에 비번 미기재**(env 파일 source).
  - `launchctl bootstrap`/`kickstart`.
- [ ] **Step 2: 설치 스모크(수동)** — 설치 후 `launchctl list | grep codex-lb-refresh`, 5분 내 출력 파일 갱신, `git status` 에 plist/env 안 잡힘(gitignore 확인).
- [ ] **Step 3: 커밋** — `feat(scripts): codex-lb refresher launchd installer(0600 env)`.

### Task 14: 앱 — Codex 계정별 렌더 + status 케이스

**Files:**
- Modify: `Sources/token-run-menubar/MenuBarContentView.swift` (providerCard, `▸` codex 활성)
- Modify: `Sources/TokenUsageCore/State/Snapshot.swift` (`accountStatusLabel` codex 케이스)
- Modify: `Sources/token-run-menubar/AccountDetailPanel.swift` (codex 행: tokens/hr+total)

**Interfaces:**
- Consumes: codex snapshot 의 `accounts`(Phase 2 데몬), `AccountUsage.tokensPerHour/totalTokens`.

- [ ] **Step 1** — `providerCard` 의 계정 렌더 조건에서 `provider == .claude` 제약 제거(양 provider). **Codex 요약은 aggregate 유지**(평균으로 안 바꿈) — codex 카드는 기존 top-line + `▸`(accounts 있으면).
- [ ] **Step 2** — `AccountDetailPanel` codex 행: tokens/hr 배지=`account.tokensPerHour`(있으면), 누적=`TotalTokens`(축약), 5h/7d 미니바, alias 라벨(이미 reader 가 Email 에 넣음).
- [ ] **Step 3** — `accountStatusLabel` 에 codex status(paused/deactivated 등) 케이스 추가(정규화된 ok 외 표시). 
- [ ] **Step 4: 빌드 + 라이브 확인(수동)** — refresher 돌린 상태에서 앱: codex 카드 `▸` → 계정 5개, tokens/hr/누적/5h·7d 표시. server/SSE 모드.
- [ ] **Step 5: 커밋** — `feat(app): codex 계정별 렌더(tokens/hr·누적·status) + aggregate 요약 유지`.

### Task 15: Phase 2 통합 검증 + 회귀

- [ ] **Step 1** — `cd server-go && go test ./... -race` green; `swift build -c release` 성공; `swift test` green.
- [ ] **Step 2** — no-codex-accounts 스냅샷 byte-identity 회귀(파일 없을 때 codex 스냅샷 기존과 동일 필드).
- [ ] **Step 3** — 외부 Air(tunnel)에서 Claude 평균·계정별·codex 계정별·tokens/hr 최종 확인.
- [ ] **Step 4: 커밋/PR** — 브랜치 정리, PR 초안.

---

## Self-Review 결과(작성자)
- **스펙 커버리지:** §6.1 평균=Task2, §6.3 Claude tokens/hr=Task4, §6.4 마스터-디테일=Task4/5, §7.1 refresher=Task11-13, §7.2 데몬(가드·reader·배선)=Task8-10, §7.3 codex UI=Task14, §5 wire=Task1/7, §8 UI 폴리시=Task6, 모드스코프=Task4(조건부), 테스트=각 태스크. ✅
- **placeholder:** 없음(코드/테스트 실제값).
- **타입 일관성:** `AccountAverages.fiveHour/sevenDay`(Task2)↔Task4 사용, `TokenRate.perHourLabel`(Task3)↔Task4/14, wire `TokensPerHour/TotalTokens`(Task7)↔reader(Task8)↔refresher used-pct 변환 주의(Task8/11) 일치.
