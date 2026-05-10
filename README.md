# token-run

Claude Code OAuth + ChatGPT Codex OAuth 토큰 사용량을 한 곳에서 보여주는 macOS
스택. **producer 데몬**(Mac mini에서 상시 가동, OAuth 쿼터 fetch + JSONL burn rate
계산 + SSE 송출)과 **consumer 메뉴바 앱**(SwiftUI MenuBarExtra, SSE 구독 또는 로컬
직접 read)으로 구성된다.

데몬은 선택적으로 터널/reverse proxy + Bearer auth를 거쳐 LAN 밖의 Mac에서도
구독 가능하며 upstream OAuth 토큰은 절대 외부로 나가지 않는다.

## 구성

### Daemon (`Sources/token-usage-daemon/`)

Hummingbird 호환 미니 HTTP/SSE 서버. 한 프로세스, 한 바이너리.

### Core (`Sources/TokenUsageCore/`)

| 모듈 | 책임 |
|---|---|
| `Auth/` | OAuth credential 파싱(Claude `~/.claude/.credentials.json`, Codex `~/.codex/auth.json`), `CredentialManager` (singleflight refresh + 매 호출 disk 재읽기 + winner-adoption), `CredentialRefreshLock` (`flock` 기반 cross-process lock) |
| `Providers/` | `api.anthropic.com/api/oauth/usage` + `chatgpt.com/backend-api/wham/usage` 호출 + 두 wire 포맷을 단일 `UsageSnapshot`으로 정규화 |
| `JSONL/` | poll-based JSONL watcher (per-file inode/size/offset cursor; 파일 사라지면 cursor prune). Codex `input_tokens`는 cached prefix 포함 형식이라 `input − cached + output + reasoning`으로 fresh-work만 추출 |
| `SQLite/` | `HermesSQLiteWatcher` — `~/.hermes/state.db` 30s polling. session row의 누적 토큰 delta를 burn rate에 ingest. 다른 source(JSONL)와 disjoint event set이라 dedup 불필요 |
| `Burn/` | 60s sliding window + EWMA(τ=20s) burn rate, hysteresis로 상태 전환 안정화 |
| `SSE/` | provider-scoped hub (`event: snapshot` / `event: auth_expired` + 10s heartbeat + bounded per-client buffer + graceful `close()`) |
| `State/` | per-provider `UsageState` actor (60s cache, 600s sticky for transient 5xx/429, account-keyed invalidation, 401 force-refresh, 429 후 5분 fetch 정지로 self-inflicted storm 방지) |

### Menubar app (`Sources/token-run-menubar/`)

SwiftUI MenuBarExtra. 4가지 connection mode:

- **자동** — 로컬 daemon(`127.0.0.1:18910`) → 원격 frp 터널 순으로 시도
- **원격 서버** — 설정에 입력한 HTTPS endpoint로 직접 SSE
- **로컬 daemon** — loopback 고정
- **로컬 직접 read** — daemon 우회. 메뉴바 앱 자체 프로세스에서 같은 코어 스택을 in-process로 돌려 OAuth + JSONL을 직접 읽음

Sparkle을 통한 자동 업데이트. 번들된 Bedlington Terrier 메뉴바 아이콘은 burn rate에 따라 idle/walk/run/sprint로 매핑.
quota row 아래에 reset 시각 표시 (`오늘 18:51 갱신 · 3시간 12분 남음` / `5/2(금) 03:00 갱신 · 5일 남음`), 30초 주기 `TimelineView`로 stale 안 보이게 자동 갱신.

### Vendor (`Vendor/{hummingbird,swift-log,swift-nio}`)

의도적으로 self-contained된 단일 파일 미니 패키지. 동시 SSE 클라이언트 ≤5에 충분.
TLS는 배포자가 선택한 reverse proxy에서 종단 처리.

### 인프라 (`infra/`)

Sparkle 공개 키와 self-hosting 예시 템플릿. 개인 서버 주소와 비밀 키는 repo에 넣지 않는다.

## 빌드 & 테스트

```sh
swift build
swift test
swift build -c release
```

## 데몬 로컬 실행

```sh
.build/release/token-usage-daemon
```

기본값:

- Bind: `127.0.0.1:18910` (override: `TOKEN_USAGE_BIND` / `TOKEN_USAGE_PORT`)
- Bearer 토큰: `~/.config/token-usage/tokens.json` (최초 실행 시 0600으로 자동 생성, 한 번 stdout 출력). override: `TOKEN_USAGE_CLAUDE_TOKEN` / `TOKEN_USAGE_CODEX_TOKEN`
- Claude OAuth: `~/.claude/.credentials.json` (`claude` CLI가 관리)
- Codex OAuth: `~/.codex/auth.json` — 반드시 **`chatgpt`** 모드. `auth_mode == "apikey"`면 `codex logout && codex login` 후 ChatGPT 계정 흐름 선택
- Refresh lock 파일: `~/.claude/.credentials.lock`, `~/.codex/auth.lock` (자동 생성, 0600)
- Burn-rate 데이터 source(자동 감지, 없으면 silent skip):
  - `~/.claude/projects/**/*.jsonl` — Claude Code CLI
  - `~/.codex/sessions/**/*.jsonl` — Codex CLI
  - `~/.hermes/state.db` — Hermes agent (codex API를 자체 호출하는 경우. cli/discord 등 source별 session row를 통해 누적 토큰 추적)

## 엔드포인트

```
GET    /healthz                                    # 무인증, 200 + {"ok":true}
GET    /version                                    # 무인증
GET    /claude/snapshot                            # Bearer claude
GET    /claude/sse                                 # Bearer claude, SSE
GET    /codex/snapshot                             # Bearer codex
GET    /codex/sse                                  # Bearer codex, SSE
```

SSE 채널:

- 연결 직후 가장 최신 `event: snapshot` 1회 즉시 송출
- `Last-Event-ID` 재연결 시에도 최신 1프레임만 replay (full history 없음)
- 10초마다 `:` 코멘트 keepalive
- JSONL 토큰 이벤트마다 새 snapshot 추가 송출
- 인증/네트워크 실패 시에도 degraded snapshot 송출 — 캐릭터가 조용히 멈추는 일은 없음
- auth state 전환 시 `event: auth_expired` 부가 송출 (UI는 `status.state` 필드로 동일 정보 수신; auth_expired는 로깅용)

## 안정성 메커니즘

| 메커니즘 | 위치 | 효과 |
|---|---|---|
| Cross-process refresh lock | `CredentialRefreshLock` (`flock`) | 데몬 + 메뉴바 LocalDirect + (잠재적) CLI 도구가 동시에 OAuth refresh 안 함 |
| Singleflight + winner adoption | `CredentialManager.refreshSingleflight` | lock 안에서 disk 재읽기. 다른 writer가 이미 갱신했으면 refresh token을 또 태우지 않고 채택 |
| Force refresh on 401 | `UsageState.refreshSnapshot` | 같은 access token으로 401 받으면 (early revocation) refresh-token 라운드트립 강제. 그것도 실패해야 authExpired |
| Account-keyed cache/sticky | `UsageState` | 로그아웃→재로그인/계정 전환 시 이전 계정 데이터를 cacheTTL/stickyTTL 동안 노출 안 함 |
| Sticky for transient errors | `UsageState` (600s) | 429 / 5xx / 408 / 425 발생 시 마지막 OK snapshot 유지. UI 깜빡임 방지 |
| Graceful shutdown | `main.swift` (`withThrowingTaskGroup` + SIGTERM/SIGINT) | SSE 클라이언트가 EOF로 깔끔하게 닫힘. 작업 중 강제 종료 없음 |
| Socket timeouts | `Hummingbird.swift` (`SO_RCVTIMEO`/`SO_SNDTIMEO` 30s) | 멈춘 peer가 shutdown을 무한 대기하게 하지 않음 |
| Cursor prune | `JSONLPoller.tick()` | 사라진 session 파일에 대한 cursor가 메모리 leak 안 됨 |
| 429 backoff (`fetchSuspendedUntil`) | `UsageState` (5분) | upstream 429 받으면 5분간 fetch 정지. 60초마다 재시도해서 rate-limit window를 갱신시키는 self-inflicted storm 차단 |
| Cached prefix 제외 (Codex JSONL) | `JSONLLineParser.parseCodex` | Codex `input_tokens`은 cached prefix 포함이라 같은 컨텍스트 후속 turn 한 번이 100배 부풀려지는 버그 fix. fresh = `input − cached + output + reasoning` |
| SQLite read-only watcher | `HermesSQLiteWatcher` | hermes 같은 외부 agent도 잡되 lock 안 잡고(query_only=ON) 영향 없이 ingest |

자세한 운영/배포/사고 대응은 [`docs/operations.md`](docs/operations.md), 데이터 source 흐름은 [`docs/data-sources.md`](docs/data-sources.md).

## 외부 배포 (producer Mac + reverse proxy)

1. `swift build -c release && sudo install -m 755 .build/release/token-usage-daemon /usr/local/bin/`
   후 `launchd/ai.openclaw.token-usage-daemon.plist` 또는 `scripts/run-nohup.sh`로 supervise.
2. 원격에서 보려면 daemon의 `127.0.0.1:18910`을 HTTPS reverse proxy 뒤에 둔다.
   메뉴바 앱 설정의 원격 endpoint에는 base URL만 입력한다.
3. SSE reverse proxy는 buffering을 꺼야 한다 (`proxy_buffering off`, `X-Accel-Buffering: no`).
4. Sparkle 업데이트는 GitHub Releases 또는 별도 HTTPS 호스트에 appcast/zip을 올린다.
5. 외부에서 검증:
   ```sh
    CLAUDE_TOK=$(jq -r .claude ~/.config/token-usage/tokens.json)
    curl -N -H "Authorization: Bearer $CLAUDE_TOK" \
        https://your-token-server.example.com/claude/sse
   ```

## launchd

```sh
swift build -c release
sudo install -m 755 .build/release/token-usage-daemon /usr/local/bin/token-usage-daemon
cp launchd/ai.openclaw.token-usage-daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/ai.openclaw.token-usage-daemon.plist
```

기존 daemon 교체 (rate limit 사고 대응 등):

```sh
launchctl unload ~/Library/LaunchAgents/ai.openclaw.token-usage-daemon.plist
sudo cp .build/release/token-usage-daemon /usr/local/bin/token-usage-daemon
launchctl load ~/Library/LaunchAgents/ai.openclaw.token-usage-daemon.plist
```

Unload만:

```sh
launchctl unload ~/Library/LaunchAgents/ai.openclaw.token-usage-daemon.plist
```

Fallback (이 호스트에서 frpc가 보이는 launchd 이슈와 같은 게 발생하면):

```sh
scripts/run-nohup.sh
```

## 메뉴바 앱 빌드 & 배포

```sh
VERSION=0.2.0 ./scripts/release.sh
```

`scripts/make-app.sh`로 `.app` 번들 생성 → `ditto`로 zip → `generate_appcast`로
Sparkle ed25519 서명 + appcast.xml 갱신. GitHub Releases로 배포할 때:

```sh
VERSION=0.2.0 GITHUB_REPOSITORY=OWNER/token-terrier GITHUB_RELEASE=1 ./scripts/release.sh
```

릴리스 appcast: `https://github.com/OWNER/token-terrier/releases/latest/download/appcast.xml`.

> 현재 host-arch only + ad-hoc signing. 배포 범위가 본인 Mac을 넘으면 universal binary +
> Developer ID 서명 + notarization 필요.

## Snapshot schema (SSE `event: snapshot`)

wire types: `Sources/TokenUsageCore/State/Snapshot.swift`. `seq`는 provider별 monotonic.
시간은 UTC ISO 8601, 지속시간은 초, percent 필드는 0–1. `status.data_source`는
첫 로컬 JSONL 이벤트 관측 시점에 `api_only`에서 `api+jsonl`로 전환.

## 문서

- [`RESEARCH.md`](RESEARCH.md) — 초기 설계 리서치 (token-run.com 분석 + GitHub 참고 레포 조사 + day-by-day plan)
- [`docs/operations.md`](docs/operations.md) — 배포/진단/사고 대응
- [`docs/data-sources.md`](docs/data-sources.md) — 데이터 source 별 형식과 처리 흐름 (OAuth quota API + JSONL × 2 + Hermes SQLite)

## Credits

License: MIT. Codex OAuth refresh parameters and endpoint
(`https://auth.openai.com/oauth/token`, `client_id=app_EMoamEEZ73f0CkXaXp7hrann`,
`scope=openid profile email`)는
[CodexBar](https://github.com/steipete/CodexBar) prior art에서 차용.
