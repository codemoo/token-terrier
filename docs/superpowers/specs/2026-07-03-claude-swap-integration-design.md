# claude-swap 통합 설계 — 메뉴바 Claude 영역에 계정별 사용량

- 작성일: 2026-07-03
- 대상: `token-run` (Token Terrier) — server-go 데몬 + SwiftUI 메뉴바 앱
- 외부 의존: [`realiti4/claude-swap`](https://github.com/realiti4/claude-swap) (`cswap`), 이 Mac 에 v0.15.1 설치, 계정 2개 등록됨

## 1. 목표

메뉴바 앱의 **Claude Code 영역**에서, `claude-swap` 이 설치돼 있으면 **보유한 모든 Claude 계정 각각의 사용량**(5시간 / 7일 window)을 볼 수 있게 한다. claude-swap 이 없으면 지금과 100% 동일하게 동작(활성 계정 1개만).

## 2. claude-swap 사실 (코드/실측 검증됨)

- `cswap --list --json` 출력 (schema v1, 안정 계약):
  ```json
  {
    "schemaVersion": 1,
    "activeAccountNumber": 2,
    "accounts": [
      { "number": 1, "email": "...", "organizationName": "...", "organizationUuid": "...",
        "isOrganization": true, "active": false, "usageStatus": "ok",
        "usage": { "fiveHour": { "pct": 7.0, "resetsAt": "2026-...Z", "countdown": "2h 12m", "clock": "21:00" },
                   "sevenDay": { "pct": 29.0, "resetsAt": "2026-...Z", ... },
                   "spend": { ... } } }
    ]
  }
  ```
- `usageStatus` ∈ `{ ok, token_expired, api_key, keychain_unavailable, no_credentials, unavailable }`.
  `ok` 이 아니면 `usage` 는 `null` 이거나 부분값.
- 각 계정 사용량을 **각 계정 자신의 OAuth 토큰**으로 `https://api.anthropic.com/api/oauth/usage` 에서 fetch (ThreadPool 병렬). → **token-run 이 이미 쓰는 것과 동일 엔드포인트.**
- fetch 결과를 `~/.claude-swap-backup/cache/usage.json` 에 **TTL 15초** 캐시. `cswap` 은 데몬이 아님 — `cswap --list` 를 누가 호출할 때만 fetch/캐시 갱신됨.
- macOS 에서 계정 credential 은 Keychain(`security`) + `~/.claude-swap-backup/credentials/*.enc` 백업. token-run 은 이걸 **읽지도 재구현하지도 않는다.**
- `pct` 단위는 **0~100** (7.0 = 7%). token-run 의 `RollingWindow.used_pct` 는 **0~1**. → **/100 변환 필요.**

## 3. 아키텍처 — Option 2 (reader-only + 외부 refresher)

핵심 원칙: **server-go 데몬은 파일만 읽는다. 절대 `cswap` 를 exec 하지 않고 네트워크도 건드리지 않는다.** ("서버는 standalone + local-filesystem 기반 유지" — AGENTS.md). `cswap` 호출(=네트워크/Keychain side-effect)은 별도 launchd job 으로 완전히 격리한다.

```
  [launchd refresher] --StartInterval 300s-->  cswap --list --json
        (외부, 격리)                                   │  (계정별 fetch + 15s 캐시)
                                                        ▼
                       ~/.config/token-usage/claude-swap-accounts.json   (schema v1 raw, 0600, atomic)
                                                        │  파일 read only
                                                        ▼
  [server-go 데몬] internal/claudeswap reader  ── used_pct=pct/100, schemaVersion==1 guard ──┐
                                                                                              ▼
                                             wire.UsageSnapshot.accounts[]  (Claude 전용, additive)
                                                        │  기존 /claude/sse 로 그대로 송출
                                                        ▼
  [메뉴바 앱] Claude 카드 하단에 계정별 행 (email + 5h/7d 바, active 강조)
```

- **활성 계정 top-line 은 그대로.** 5h/7d 바 + 달리는 개(burn)는 지금처럼 `~/.claude/.credentials.json` → 직접 `/api/oauth/usage` fetch(60초 주기) 로 유지한다. accounts[] 는 **순수 추가**.
  - **Invariant (active identity):** top-line 은 `~/.claude` 활성 계정을 신뢰한다. accounts[] 의 `active:true` 행은 **표시 전용**이며 top-line 을 바꾸지 않는다. 계정 전환 직후 accounts 파일이 최대 5분 stale 하면 `active` 강조가 잠깐 어긋날 수 있으나 다음 refresh 에 self-heal. 억지로 reconcile 하지 않는다.
- `cswap` 이 Keychain 프롬프트/hang 에 걸려도 **refresher 만 영향**받는다 (파일이 stale 될 뿐). 데몬 poll 루프는 무관 — Option 2 를 택한 핵심 이유.

### 대안(기각): Option 1 — 데몬이 직접 `cswap` exec

데몬이 poll 마다 subprocess 로 `cswap` 실행. 기각 이유: (a) launchd/nohup 환경 PATH 에 `~/.local/bin` 없음, (b) Keychain 프롬프트 시 **데몬 poll 전체가 hang**, (c) subprocess timeout/zombie/동시성 관리 부담, (d) AGENTS.md "standalone + local-filesystem" 위배. codex(gpt-5.5 xhigh) 비판 라운드에서도 Option 2 방향을 지지.

## 4. 컴포넌트

### A. Refresher (로컬 infra — launchd + 설치 스크립트)

- **`scripts/claude-swap-refresh.sh`** (repo 커밋, generic, 사설정보 없음):
  - `CSWAP_BIN`(기본 `$HOME/.local/bin/cswap`) 을 실행, stdout 을 `TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS`(기본 `$HOME/.config/token-usage/claude-swap-accounts.json`) 에 **atomic write** (`mktemp` → `chmod 600` → `mv -f`).
  - **single-flight**: `mkdir` 락으로 중복 실행 차단. 락 잡힌 중이면 즉시 exit 0 (stuck cswap 이 후속 실행을 막지 않게, 파일은 그냥 stale).
  - **keep-last-good**: `cswap` 실패(exit≠0) 또는 빈 출력이면 기존 파일 보존, tmp 삭제.
  - (하드닝 옵션) `perl -e 'alarm N; exec @ARGV'` 류로 watchdog timeout.
  - **emails/계정 목록을 로그로 남기지 않는다.**
- **`scripts/install-claude-swap-refresh.sh`** (repo 커밋, generic): `~/Library/LaunchAgents/ai.openclaw.token-usage-claude-swap-refresh.plist` 를 **생성**(StartInterval 300, RunAtLoad) 하고 `launchctl bootstrap`. **생성된 plist 자체는 machine-local (`launchd/`, untracked)** — AGENTS.md "launchd 파일 커밋 금지" 준수.

### B. Accounts 계약 파일

- 경로: `~/.config/token-usage/claude-swap-accounts.json` (env override `TOKEN_USAGE_CLAUDE_SWAP_ACCOUNTS`), 권한 `0600`.
- 내용: `cswap --list --json` **원본 그대로** (schema v1). refresher 는 dumb pipe — 변환/판단 로직 없음. 모든 파싱·검증은 Go reader(테스트 가능)에 둔다.
- freshness: 파일 **mtime** 으로 판단 (출력 top-level 에 timestamp 없음).

### C. Go reader — `internal/claudeswap`

- `reader.go`:
  - 파일 read → JSON 파싱 → **`schemaVersion == 1` guard** (아니면 무시, accounts 없음 취급).
  - 각 account 를 `wire.AccountUsage` 로 매핑: `pct/100 → used_pct`, `usageStatus → status`, `usage==null`/window 누락 tolerant.
  - 반환: `([]wire.AccountUsage, updatedAt time.Time, ok bool)`.
- `holder`(thread-safe): mtime 변경 시 재파싱 캐시. 기존 60초 Claude tick(또는 경량 파일 watcher)에서 갱신. getter `Current() ([]wire.AccountUsage, *string)`.
- `main.go` 배선 후 **Claude 스냅샷 emit 시점에 enrich**. 정확한 주입 지점(예: `NormalizeClaude` 결과 후처리 vs SSE publish decorator)은 구현 계획에서 확정.
- 로그는 **개수만**(`claude-swap accounts: 2`), email 금지.

**관련 선행 코드 — `server-go/internal/codexlb/` (untracked, 2026-06-10):** 과거 codex-lb 통합 시도로 작성됐으나 커밋/배선 안 된 패키지. 데몬이 codex-lb `/v1/usage` 를 **HTTP fetch** 해 **집계(aggregate)** Codex 스냅샷으로 normalize 한다 (계정별 아님). claude-swap 은 HTTP API 가 없고 CLI(`cswap`) 뿐이라 **파일 기반이 유일한 clean 옵션** — 이 점이 Option 2 를 더 강화한다. 단, 그 패키지의 **컨벤션은 재사용**한다: env-gating(`TOKEN_USAGE_DISABLE_*`) + `Snapshot()→(snap, ok)` fallback 플래그, 그리고 헬퍼 `parseResetAt`(RFC3339Nano/RFC3339/unix), `clamp`, `remainingSeconds`, `firstNonEmpty`. 이 헬퍼들은 공유 위치(예: `internal/wire` 또는 작은 `internal/normutil`)로 올리거나 복제한다 — 계획에서 확정. (codexlb 패키지 자체는 이번 작업 범위 밖: 그대로 두거나 별도 결정.)

### D. Wire schema 추가 (additive, Claude 전용)

```go
type AccountWindow struct {
    UsedPct  float64 `json:"used_pct"`   // 0~1 (cswap pct/100)
    ResetsAt *string `json:"resets_at"`
}
type AccountUsage struct {
    Number   int            `json:"number"`
    Email    string         `json:"email"`
    Active   bool           `json:"active"`
    Status   string         `json:"status"`      // ok|token_expired|api_key|keychain_unavailable|no_credentials|unavailable
    FiveHour *AccountWindow `json:"five_hour"`
    SevenDay *AccountWindow `json:"seven_day"`
}
// UsageSnapshot 에 추가:
Accounts        []AccountUsage `json:"accounts,omitempty"`
AccountsUpdated *string        `json:"accounts_updated_at,omitempty"`  // RFC3339, 파일 mtime
```

- `omitempty` — claude-swap 미탐지 / codex provider 스냅샷은 오늘과 **byte-identical**. 기존 Swift Codable 은 unknown key 무시, 신규 Swift 는 optional 로 nil 디코드 → 하위호환.
- accounts[] 는 **Claude 스냅샷에만** 실린다 (codex 는 절대 안 실림).

### E. Swift 메뉴바 렌더링

- `Snapshot.swift`: `UsageSnapshot` 에 `accounts: [AccountUsage]?`, `accountsUpdatedAt: String?` optional 추가 + `AccountUsage`/`AccountWindow` 디코더.
- `MenuBarContentView.providerCard(.claude)`: 기존 5h/7d 행 아래에, `accounts` 가 비어있지 않으면 Divider + 계정별 compact 행 렌더 — email + 5h/7d 미니 바 + active dot. `status != ok` 이면 바 대신 라벨(`api_key`→"할당량 없음", `token_expired`, `keychain_unavailable` 등). `accountsUpdatedAt` 이 오래되면(예: > 10분) 은은하게 dim/표시.
- **새 provider enum / 새 카드 안 만든다.** Claude 섹션에 접어넣음.
- **email 은 메뉴바에 그대로 노출한다 (마스킹 안 함).** 본인 계정이고 로컬 UI 이므로 허용 — 사용자 확정 2026-07-03. (단, 데몬/refresher **로그**에는 여전히 남기지 않음 — §6.)

## 5. Invariant & 엣지케이스 (codex 반영)

| # | 케이스 | 처리 |
|---|--------|------|
| 1 | `pct` 0~100 → 0~1 변환 | reader 에서 `/100`. 누락 시 UI 과대표시 → 테스트로 고정. |
| 2 | `usageStatus != ok` | `status` 그대로 전달, window 는 nil 허용. UI 는 라벨. |
| 3 | `schemaVersion != 1` | accounts 무시(feature dormant), top-line 정상. |
| 4 | 계정 0개 / 파일 없음 / 파싱 실패 | accounts 미포함. 기존 동작. |
| 5 | `resetsAt` 파싱 실패 / 누락 | 해당 window nil, 나머지 유지. |
| 6 | 중복 email (토큰 무효화 캐스케이드) | number 로 구분해 그대로 표시. |
| 7 | active(파일) ≠ ~/.claude 활성 | top-line 은 ~/.claude 신뢰. reconcile 안 함(§3). |
| 8 | 파일 stale (refresher 중단) | mtime 으로 stale 표시, 마지막값 유지. 사라지게 하지 않음. |
| 9 | cswap 버전/스키마 변경 | schemaVersion guard 로 안전 degrade. |

## 6. Rate-limit / privacy

- **429**: 계정별 fetch 는 refresher 안에서만, **StartInterval 300초**(cswap 15s TTL 훨씬 위)로 발생. window 가 5h/7d 라 5분 granularity 는 무의미하게 충분. 데몬은 fetch 를 유발하지 않으므로 기존 top-line 의 429 리스크에 **아무것도 더하지 않는다** (계정 조회 비용은 refresher 로 격리·저빈도화).
- **privacy**: email 은 데몬/refresher **로그에 절대 남기지 않는다**. 계약 파일·plist 는 `0600`. 사설 hostname/token 커밋 금지(AGENTS.md).

## 7. 테스트

- **Go (핵심)**: reader 는 "파일 → []AccountUsage" 순수 함수 → table test 로 전부 커버 (정상 / schema≠1 / 0계정 / status 변형 / pct 변환 / window 누락 / malformed / stale mtime). **네트워크·HTTP mock 불필요** — Option 2 의 큰 이점.
- **refresher script**: shellcheck + atomic/lock/keep-last-good 수동 검증.
- **Swift**: accounts 를 담은 샘플 스냅샷으로 preview 렌더 확인.
- **회귀**: claude-swap 미설치 시 `/claude/snapshot` JSON 이 오늘과 byte-identical(accounts 키 부재) 확인.

## 8. Scope 밖 (YAGNI)

- local-direct 모드(서버 없이 앱이 직접 읽기)의 계정별 표시 — v1 은 server 경로만. 단 UI 는 소스 무관하게 accounts[] 를 렌더하므로 나중에 local-direct 에 reader 만 붙이면 동작(forward-compatible).
- Codex 멀티계정(과거 codex-lb 아이디어) — 이번 작업 아님.
- top-line 집계(aggregate/least-headroom) — top-line 은 활성 계정 유지.
- 계정별 burn rate / today tokens — cswap 은 quota window 만 제공. burn 은 활성 계정만.

## 9. 결정 로그 (locked)

1. **Option 2** — 데몬 read-only + 외부 launchd refresher (사용자 선택 2026-07-03).
2. top-line = `~/.claude` 활성 계정, 불변. accounts[] 는 additive.
3. refresher 는 `cswap --list --json` **원본**(schema v1)을 `~/.config/token-usage/claude-swap-accounts.json`(0600, atomic, mkdir-lock, keep-last-good, StartInterval 300s) 에 기록.
4. 데몬은 파일만 read, `cswap` exec 안 함. `schemaVersion==1` guard, `pct/100`, email 로그 금지.
5. 메뉴바는 Claude 카드에 접어넣음. 새 provider 없음.
6. 메뉴바 UI 에 email **그대로 노출**(마스킹 안 함, 사용자 확정 2026-07-03). 로그에는 계속 미기록.

## 10. 배포 산출물 (이 Mac 적용 + 프로젝트 반영)

- **프로젝트 반영(커밋)**: `internal/claudeswap` reader + wire 추가 + Swift 렌더 + `scripts/claude-swap-refresh.sh` + `scripts/install-claude-swap-refresh.sh` + `docs/data-sources.md` 갱신(claude-swap source 문단).
- **이 Mac 적용(로컬)**: server-go 재빌드 → `/private/tmp/token-terrier-daemon` 교체 → 데몬 재기동, `install-claude-swap-refresh.sh` 로 refresher 등록, 메뉴바에서 2계정 표시 검증. (생성 plist 는 `launchd/`, untracked.)
