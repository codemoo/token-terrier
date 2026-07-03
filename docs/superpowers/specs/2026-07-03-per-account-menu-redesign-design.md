# Per-account menu redesign — Claude 평균 요약 + 계정별 마스터-디테일 + Codex per-account + 계정별 시간당 토큰

- **날짜:** 2026-07-03
- **상태:** 설계 확정 (사용자 승인). 구현 계획(writing-plans) 대기.
- **관련:** [[token-run-claude-swap-integration]], [[token-run-monitoring-daemon-ops]], `docs/superpowers/specs/2026-07-03-claude-swap-integration-design.md`

## 1. 목표

메뉴바 앱의 **Claude Code 기본 뷰를 cswap 계정들의 사용량 평균**으로 바꾸고, 카드를 클릭하면 **오른쪽으로 패널이 슬라이드**되며 계정별 상세를 보여준다. **Codex(codex-lb)도 같은 서브메뉴 방식**으로 계정별을 본다(단 Codex 기본 뷰는 계정 평균이 아니라 codex-lb 풀 aggregate 유지). 계정별 상세에는 **시간당 토큰 사용량**을 함께 표시한다. 전반적으로 **UI 를 보기 좋게 폴리시**한다.

## 2. 현재 상태 (변경 대상)

- 앱: `Sources/token-run-menubar/MenuBarContentView.swift` — `MenuBarExtra(.window)`, 폭 320 고정 VStack. `providerCard(.claude/.codex)` 가 top-line(활성계정 5h/weekly, burn) 렌더. Claude 는 `snapshot.accounts` 있으면 **인라인**으로 계정별(`accountRow`/`accountMiniBar`) 붙임. Codex 는 계정별 데이터 없음. 앱은 `snapshot.burnRatePerMinute`(활성계정, JSONL 기반)를 이미 가짐.
- 데몬(Go, `server-go`): `wire.AccountUsage{Number,Email,Active,Status,FiveHour,SevenDay}`, `UsageSnapshot.Accounts []AccountUsage`(omitempty). `state.AccountsProvider`/`SetAccountsProvider`/`decorateAccounts`(현재 `snap.Provider != ProviderClaude` 조기반환 = Claude 전용). Claude 계정별은 `internal/claudeswap.Reader`(파일 mtime 캐시)가 외부 refresher 가 쓴 `~/.config/token-usage/claude-swap-accounts.json` 을 읽어 채움.
- Codex top-line: `internal/codexlb.Snapshotter`(LocalSnapshotter)가 API키로 `GET /v1/usage`(aggregate 합산 credits)를 읽음. `cmd/daemon/main.go:93` 배선.

## 3. 승인된 결정 (사용자 확정)

| # | 결정 |
|---|---|
| 방식 | **A. 창 안 마스터-디테일**(오른쪽 슬라이드 패널). 리치 UI 유지. |
| Claude 기본뷰 | **계정 평균**(status=ok, 5h/7d 윈도우별 독립 산술평균). 활성계정 top-line 대체. |
| Codex 기본뷰 | **codex-lb 풀 aggregate 유지**(현행). 평균 아님 — 서브메뉴로만 계정별. |
| Codex per-account | **codex-lb 대시보드 인증까지** 진행(Phase 2). |
| 계정별 시간당 토큰 | **비대칭(옵션 A)**: Codex = 계정별 tokens/hour(샘플링 델타) + 누적 토큰. Claude = **활성계정만** tokens/hour(밥풀이 burn), 보유계정은 pct(토큰 데이터 없음). |
| "옆으로" 리스크 | 수평 패널 구현 + **온디바이스 flicker 검증 → 심하면 수직 disclosure 폴백** 수용. |
| 진행 | **2단계**: Phase 1 Claude(신규 secret 없음) → 검증 → Phase 2 Codex refresher(비번 보유). |
| Codex 행 표시 | `alias`/`displayName` 우선(email 중복), email 병기. Claude 는 email. |
| top-line 저하 | per-account/평균은 **독립 데이터 소스로 계속 렌더**(top-line 429/stale 여도). |
| UI | **폴리시**: 계정별 카드(진행바 + tokens/hr 배지 + 리셋), 정렬/간격/색/애니메이션 정돈. |
| burn dog | 메뉴바 아이콘 burn_rate 기반 — **불변**. |

### 데이터 가용성 근거 (라이브 확인)
- **Codex(codex-lb):** 계정별 누적 토큰 `requestUsage.totalTokens`(+requestCount/costUsd) 있음. "지난 1시간 토큰"은 직접 안 줌(`/api/usage/window`·`/history` 는 credits/pct) → **refresher 가 `totalTokens` 주기 샘플링, 델타/시간으로 tokens/hour 계산.**
- **Claude(cswap):** 계정별은 **pct(5h/7d)만** — 토큰 카운트 0. 보유(비활성) 계정 토큰 데이터는 어디에도 없음. 활성계정만 JSONL burn 으로 tokens/hour 가능.

## 4. 아키텍처 (3계층, 2단계)

```
[외부 refresher(launchd)]  --derived json-->  [로컬 파일]  --read-->  [데몬(Go)]  --SSE-->  [앱(SwiftUI)]
  Phase2: codex-lb login → GET /api/accounts    codex-lb-accounts.json   codexlb accounts Reader     평균/마스터-디테일/토큰배지
          + prev-sample 델타로 tokensPerHour     (+samples 사이드카)      → decorateAccounts(codex)
  (기존) cswap → claude-swap-accounts.json →     claudeswap.Reader → decorateAccounts(claude)
```

**불변식(전제):** 데몬은 **standalone + local-filesystem** 유지(AGENTS.md:104). 데몬은 codex-lb 에 **로그인하지 않고 비번/쿠키를 보유하지 않는다** — 파일만 읽음. (verify 가 지적한 AUTH Option A "데몬 auto-login" = **명시적 기각**: AGENTS.md 위반 + 세션만료 stuck 재발 + auth-failure self-exit 가드가 decoration 계층 미포함.)

## 5. 데이터 모델 / wire

- **wire 추가는 additive omitempty 만** — 없을 때 필드 생략되어 Claude·no-codex-accounts 스냅샷 byte-identity 유지.
  - `AccountUsage` 에 `TokensPerHour *float64 json:"tokens_per_hour,omitempty"` (Codex refresher 채움; Claude 는 nil, 앱이 활성계정에 한해 burn 으로 대체).
  - `AccountUsage` 에 `TotalTokens *int64 json:"total_tokens,omitempty"` (Codex 누적; Claude nil).
- **monthly 윈도우 드롭**(v1). 5h(primary)/7d(secondary) 만.
- codex 계정 → `AccountUsage` 매핑(refresher 가 derived JSON 으로 이미 정규화해서 내려줌 → Go reader 는 단순 파싱):
  - `Number` = `accountId` 안정정렬 synthetic index(ForEach id 안정). email 은 unique 아님 → 키 아님.
  - `Email` = codex `email`. 라벨은 앱에서 `alias`/`displayName` 우선(§7.3).
  - `Active` = `status == "active"`.
  - `Status` = 정규화: `active → "ok"`, 그 외 pass-through.
  - `FiveHour.UsedPct` = `clamp(1 − primaryRemainingPercent/100, 0, 1)`; null → 윈도우 nil.
  - `SevenDay.UsedPct` = `clamp(1 − secondaryRemainingPercent/100, 0, 1)`.
  - `*.ResetsAt` = `resetAtPrimary`/`resetAtSecondary`.
  - `TokensPerHour` = refresher 델타(§7.1). `TotalTokens` = `requestUsage.totalTokens`.
  - ⚠️ codex-lb 는 **remaining %**(사용%=100−remaining). 5h 사용 0 이면 `primaryRemainingPercent=100` 강제 — 버그 아님.

## 6. Phase 1 — Claude 평균 + 마스터-디테일 UI + 활성계정 tokens/hour (앱 전용, 신규 secret 없음)

이미 내려오는 claude-swap `accounts[]` + 기존 `burnRatePerMinute` 만 사용. 데몬/데이터 변경 없음.

### 6.1 평균 계산 (앱, in-view)
- **정의(못박음):** 각 윈도우(5h,7d) 독립. `status=="ok"` & 그 윈도우 non-nil 계정들의 `usedPct` 산술평균. 자격 계정 0 → **nil(막대 없음)**, 0%/활성계정 폴백 아님.
- 계정 없으면(단일/no-swap) → 기존 활성계정 top-line 그대로.

### 6.2 좌측 요약 카드
- Claude: 계정 있으면 **평균 5h/7d 막대**(quotaRow 스타일) + `▸` + "N 계정" 캡션. 없으면 현행 top-line.
- **top-line 저하 독립성:** `accounts` 있으면 `status.state` 가 degraded(429/stale/authExpired)여도 평균·계정별 렌더. degraded 는 작은 인라인 노트로 강등.
- burn(tok/min) 행 유지.

### 6.3 계정별 시간당 토큰 — Claude
- **활성계정 행**: `snapshot.burnRatePerMinute * 60` 을 **tokens/hour 배지**로(활성계정에만). 보유계정 행: `TokensPerHour` nil → 배지 없음(pct 만).
- 표기: `k/M` 축약(예 `1.2M tok/h`).

### 6.4 마스터-디테일 패널 (수평 A, 폴백 있음)
- `@State selectedProvider: Provider?` — chevron 토글, 한 번에 하나. 닫기/뒤로 어포던스.
- 열리면 `HStack{ 좌측요약(320) | 우측패널(~300) }`, 상태바인딩 `.frame(width:)` + slide transition + `.clipped()` + `.animation(value: selectedProvider)`. 닫힘 320 복귀. `.onDisappear` 에서 `selectedProvider=nil`(재오픈 off-screen 방지 안전장치).
- 우측 패널: 계정 리스트(폴리시된 `accountRow`), 활성 `●`, tokens/hr 배지, 리셋. 헤더(provider + 닫기). 로딩/빈/에러.
- 클릭 영역 `.buttonStyle(.plain)` + `.contentShape(Rectangle())` + subtle selected 배경.
- **온디바이스 검증 게이트:** `.window` 수평 리사이즈는 NSWindow 리사이즈가 SwiftUI 애니메이션과 frame-sync 안 됨 → 깜빡임/클리핑 OS 의존. **실기 검증 필수.** 잰크 심하면 → **수직 disclosure** 폴백(기능 동일). 계획에 escape hatch 명시.

### 6.5 모드 스코프
- per-account/평균은 **server/SSE 모드 전용.** local-direct 는 데몬 우회 → 계정 없음 → Claude 는 기존 활성계정 top-line. 문서화.

## 7. Phase 2 — Codex per-account + 시간당 토큰 (검증된 Phase 1 이후, 사용자 비번 승인 완료)

### 7.1 외부 refresher (codex-lb 인증 + 토큰 샘플링 — 비번은 여기만)
- 신규 **Python 스크립트** `scripts/codex-lb-accounts-refresh.py` + installer(launchd, `StartInterval` 예 300s). (bash 로는 델타 계산이 지저분 → Python.)
- 매 실행 **fresh login**(쿠키 캐시/보관 안 함 → 세션 TTL·만료 무관, stuck 재발 원천 차단):
  1. `POST http://127.0.0.1:2455/api/dashboard-auth/password/login` `{"password":"<env>"}` → `Set-Cookie codex_lb_dashboard_session`.
  2. `GET /api/accounts`(쿠키) → 계정별 5h/7d remaining%, status, alias, `requestUsage.totalTokens`.
  3. **tokens/hour 델타:** 사이드카 `~/.config/token-usage/codex-lb-samples.json`(0600) 에서 accountId 별 직전 `{totalTokens, ts}` 로드 → `tokensPerHour = (now.totalTokens − prev.totalTokens) / ((now.ts − prev.ts)/3600)`. 첫 실행/음수 델타(리셋)/신규 계정 → nil. 이번 샘플로 사이드카 갱신(atomic).
  4. **derived JSON** 을 atomic write(mktemp→chmod600→mv) → `~/.config/token-usage/codex-lb-accounts.json`. shape: `{schemaVersion, accountsUpdatedAt, accounts:[{number, accountId, email, alias, displayName, planType, status, fiveHourPct, sevenDayPct, resetAtPrimary, resetAtSecondary, totalTokens, tokensPerHour}]}`. status 는 **raw(active/paused/…) 그대로** 내려보내고 정규화는 **Go reader 단일 지점**(§7.2, §9.4)에서 한다(테스트 지점 일원화).
- **검증:** 승격 전 top-level `accounts` 가 배열인지 확인(401/오류 body 도 valid JSON → `json.load` 만으론 부족; 401 이면 last-good 유지). mkdir-lock single-flight, keep-last-good.
- **login 실패 backoff**(비번 오류/rotate 시 rate-limit·audit 스팸·lockout 방지). password-login 은 client IP 당 rate-limited.
- **비번 위치(불변식):** refresher env 에만 — **0600 sourced env 파일**(예 `~/.config/token-usage/codex-lb-refresh.env`, gitignore)을 launchd 잡이 source. **plist body(EnvironmentVariables)에 넣지 않음**(world-readable) · **데몬 env 아님** · **git 금지** · email/alias/토큰수 로깅 금지.
- codex-lb TOTP: 이 인스턴스 `totpConfigured:false` → 비번만. (켜지면 refresher 에 seed 추가 — 데몬 아님.)

### 7.2 데몬 (Go)
- `decorateAccounts`(usage_state.go:128)의 `snap.Provider != ProviderClaude` 조기반환 **제거** → provider-무관. **불변식: accounts provider 는 State.provider 와 매칭.** lock 규율 유지(s.mu 로 s.accounts 만 읽고 unlock 후 `ap.Accounts()`).
- 새 `internal/codexlb` accounts Reader(claude-swap Reader 미러, 파일 mtime 캐시 + 2s throttle) — derived JSON → `wire.AccountUsage`(TokensPerHour/TotalTokens 포함). status 정규화 `active→ok`(refresher 가 안 했으면 여기).
- `cmd/daemon/main.go`: `codexState.SetAccountsProvider(codexReader)` 배선(env-gate: 파일 존재 or `TOKEN_USAGE_DISABLE_CODEX_ACCOUNTS != "1"`).
- **테스트:** `TestCodexNeverDecorated`(accounts_test.go:46) → **갱신/교체**. status 정규화 + remaining→used + tokensPerHour 파싱 Go 테이블 테스트.

### 7.3 앱 (Codex 확장)
- `MenuBarContentView` 의 `if provider == .claude` → **provider-무관** 완화, codex `▸` 활성.
- **Codex 요약 = codex-lb 풀 aggregate 유지**(rolling5h/weekly credits). 평균 아님. 서브메뉴만 계정별.
- codex 계정 행: `alias`/`displayName` 우선(email 중복), email 병기. **tokens/hr 배지**(`TokensPerHour`) + 누적(`TotalTokens`, 축약) + 5h/7d + 리셋.
- `accountStatusLabel`(Snapshot.swift:267) 에 codex status 케이스 추가.

## 8. UI 폴리시 (보기 좋게)
- 계정 행을 **카드형**으로: 상단 라벨(활성 ● + alias/email) + 우측 tokens/hr 배지, 하단 5h/7d 미니 진행바(색상: 여유=green계열, 임박=orange/red). 간격/정렬/타이포 정돈.
- 평균 요약: 큰 진행바 2개(5h/7d) + "N 계정 · 활성 alias" 캡션.
- 마스터-디테일 전환에 부드러운 slide + 우측 패널 헤더에 provider 아이콘.
- tokens/hr 배지 `k/M` 축약, 리셋 상대시간(기존 `resetText`) 재사용.
- 구현 시 **frontend-design 스킬**로 시각 마감. 다크/라이트 대응, 접근성 라벨.

## 9. 보안 / 불변식 (must-fix)
1. **비번 위치:** codex-lb 비번은 refresher env(0600)만. plist body/데몬/git 금지. 스펙·로그·응답에 값 미기재.
2. **데몬은 로그인 안 함**: 파일만 read. standalone + local-fs.
3. **refresher fresh-login-per-run** + accounts 배열 검증 + login backoff + keep-last-good + 샘플 사이드카 atomic.
4. **status 정규화** 단일 지점(active→ok). Swift 케이스 추가.
5. **평균 정의** 단일화(§6.1) — 윈도우별, ok+non-nil, 없으면 nil.
6. **wire = additive omitempty 만**(TokensPerHour/TotalTokens). 없을 때 byte-identity 유지. monthly 드롭.
7. **결정적 정렬**: codex Number 는 account_id 안정정렬.
8. **provider-매칭 reader** 전제로만 decorateAccounts 가드 완화. TestCodexNeverDecorated 갱신.
9. **모드 스코프**: server/SSE 전용. local-direct 계정 없음.
10. **codex 요약 basis**: aggregate(credits) 유지 — 평균과 혼용 금지.
11. **tokens/hour 델타**: 첫샘플/음수(리셋)/신규계정 → nil(0 아님). Claude tokens/hr 은 활성계정만(burn), 보유계정 nil.

## 10. 테스트
- Go: codex accounts Reader 파싱/매핑/status 정규화/remaining→used/null 윈도우/TokensPerHour·TotalTokens 파싱 table. decorateAccounts codex 경로 + provider 매칭. `go test -race`.
- Python(refresher): 델타 계산(첫샘플/정상/음수리셋/신규계정), accounts 배열 검증, atomic write, 401→last-good. 
- Swift: 평균(ok 필터/윈도우별/nil), 마스터-디테일 selection/width, codex 요약=aggregate, alias 라벨, tokens/hr 배지 축약(k/M), 활성계정 burn→tokens/hr.
- 수동(실기): `.window` 수평 리사이즈 flicker(폴백 판단), 외부 Air(tunnel)에서 Claude 평균·계정별·codex 계정별·tokens/hr 표시.

## 11. Non-goals / 유예
- monthly(30d) 윈도우 — v1 제외.
- codex-lb TOTP 로그인 — 현재 비활성.
- 데몬 auto-login(AUTH Option A), guest login(비활성), trusted-header bypass — 기각.
- local-direct 모드 per-account — 범위 밖.
- Claude 보유(비활성) 계정 tokens/hour — 데이터 없음(활성계정만).

## 12. 미해결 리스크
- `.window` 수평 리사이즈 잰크(§6.4) — 실기 검증 전까지 미확정. 수직 disclosure 폴백 준비.
- codex-lb tokens/hour 는 refresh 간격(≈5분) 델타의 시간환산 → 근사치(순간율 아님). 간격/누락 시에도 (Δ토큰/Δt) 로 안정.
- codex-lb 업그레이드로 encryption.key/store.db 리셋 시 비번 해시 변경 가능 → refresher login 실패 → aggregate 로 graceful degrade(데몬 무영향).
