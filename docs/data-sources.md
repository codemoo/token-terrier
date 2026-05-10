# Data Sources — 어디서 무엇을 어떻게 가져오는가

token-usage daemon 이 한 응답을 만들 때 **세 가지 종류**의 source 에서 데이터를 모은다.

```
                                          ┌─────────────────────────────┐
                                          │         UsageSnapshot       │
                                          │  (SSE 로 송출, 메뉴바 표시)  │
                                          └─────────────▲───────────────┘
                                                        │
                  ┌─────────────────────────────────────┴──────────────────────────────────────┐
                  │                                                                            │
                  ▼                                                                            ▼
       (A) Quota / 5h / 주간 / credits                                  (B) burn rate · today total · sessions
        ── OAuth quota API ──                                            ── 로컬 사용량 source ──
                  │                                                                            │
   ┌──────────────┴──────────────┐                              ┌──────────────┬──────────────┐
   ▼                              ▼                              ▼              ▼              ▼
 Claude:                       Codex:                        JSONL          JSONL         SQLite
 api.anthropic.com/            chatgpt.com/                 (Claude         (Codex        (Hermes
   api/oauth/usage              backend-api/wham/usage       Code CLI)       CLI)          agent)
```

(A) 와 (B) 는 둘 다 `UsageState` 안에서 합쳐진다. (A) 는 1분에 한 번 fetch / cache, (B) 는 token event 가 발생할 때마다 push 로 BurnTracker 에 들어간다.

---

## (A) Quota / 5h / 주간 / credits — OAuth API

### Claude — `https://api.anthropic.com/api/oauth/usage`

- 인증: `Authorization: Bearer <oauth-access-token>`, `anthropic-beta: oauth-2025-04-20`
- 응답: 5h window, 주간 window, credits (있는 계정만)
- 파싱: `Sources/TokenUsageCore/Providers/RawUsageResponses.swift` → `UsageNormalizer` → `UsageSnapshot`

### Codex (ChatGPT) — `https://chatgpt.com/backend-api/wham/usage`

- 인증: 같은 OAuth access token. 단, `auth.json` 의 `auth_mode == "chatgpt"` 여야 함 (apikey 모드는 endpoint 다름)
- 응답: 5h window, 주간 window, plan_type 등
- 파싱: 위와 동일

### 요청 빈도

- daemon 의 `claudeRefreshTask` / `codexRefreshTask` 가 **60 초 주기**로 호출
- `/sse` / `/snapshot` HTTP 핸들러가 호출될 때도 background 로 trigger (cache 안 만료됐으면 noop)
- `UsageState.cacheTTL = 60s`: 그 안엔 cached 응답
- `UsageState.stickyTTL = 600s`: transient(5xx/429/408/425) 발생 시 마지막 OK snapshot 을 유지
- HTTP 429 받으면 `fetchSuspendedUntil = now + 5 min` 로 잠시 fetch 자체 정지 (self-inflicted storm 차단)

### account-keyed cache 무효화

`OAuthCredential.accountKey` (account_id / email / token tail) 로 cache · sticky 가 키잉된다. 로그아웃 → 재로그인 / 계정 전환 시 이전 계정 데이터를 cacheTTL/stickyTTL 동안 노출하지 않도록.

---

## (B) Burn rate · today total · sessions — 로컬 source

3 개의 watcher 가 각각 자기 형식의 source 를 polling 한다. 모두 `TokenEvent` 를 만들어 `BurnTracker` 에 ingest 한다. `BurnTracker` 는 60s sliding window + EWMA(τ=20s) 로 burn rate 를 계산하고 today total / today sessions 를 누적한다.

세 source 는 **disjoint event set** 이라 dedup 불필요 — 한 prompt 는 한 호출이고, 그 호출은 정확히 한 source 에만 기록된다.

### B-1) Claude Code CLI — JSONL

- 위치: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`
- 라인 형식: `{"type":"assistant","message":{"model":"…","usage":{...}},"sessionId":"…"}`
- fresh tokens = `input_tokens + output_tokens + cache_creation_input_tokens`
- `cache_read_input_tokens` 는 제외 (replay, 거의 무료, 분당 burn rate 가 비현실적으로 부풀려짐)
- 파서: `Sources/TokenUsageCore/JSONL/JSONLLineParser.swift::parseClaude`

### B-2) Codex CLI — JSONL

- 위치: `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl`
- 라인 형식: `{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{…}}}}`
- fresh tokens = `(input − cached) + output + reasoning`
- 핵심: codex 의 `input_tokens` 는 cached prefix **포함** 카운트 (claude 의 `cache_read_input_tokens` 처럼 별도 컬럼이 아니라 합산된 값). 빼지 않으면 같은 컨텍스트 후속 turn 한 번이 input 100k+ 로 잡혀 burn rate 가 두 자릿수 배로 부풀려짐
- 파서: `Sources/TokenUsageCore/JSONL/JSONLLineParser.swift::parseCodex`

### B-3) Hermes agent — SQLite

- 위치: `~/.hermes/state.db`
- 테이블: `sessions(id, source, model, billing_provider, started_at, ended_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, …)`
- watcher: `Sources/TokenUsageCore/SQLite/HermesSQLiteWatcher.swift`
- 동작:
  - 30 초 주기 polling, **read-only** (`SQLITE_OPEN_READONLY` + `PRAGMA query_only=ON`) — hermes 의 lock 영향 없음
  - in-memory `[session_id: lastSeenFreshTokens]` map 으로 delta 추적
  - 첫 tick 은 baseline 만 등록. 두 번째 tick 부터 실제 delta 를 발행
  - `ended_at` 이 NULL 이 아닌 row 는 마지막 delta 발행 후 map 에서 제거 (메모리 누수 방지)
- fresh tokens = `input + output + reasoning` (cache_read · cache_write 제외)
- provider 분기: `billing_provider == "openai-codex"` → `.codex`; `"anthropic"` → `.claude`; 그 외 무시
- DB 파일이 없으면 watcher 는 silent skip — hermes 안 쓰는 환경에 영향 없음

### JSONL poller 의 "EOF 부터 read" 정책

`JSONLPoller` 는 처음 보는 파일을 **EOF 에서 cursor 를 시작**한다. 즉 daemon 시작 시점 이전에 작성된 기존 라인은 무시. 이유:

- daemon 재시작마다 여러 백만 토큰의 historic 라인이 burn rate window 에 burst 로 들어가면 그래프가 비현실적으로 튐
- today total 도 daemon 재시작 후 0 부터 다시 누적 → 사용자 머릿속 "오늘 사용량" 과 안 맞을 수 있음. 단점은 인지하고 있고, 향후 "자정부터 backfill" 을 옵션으로 추가하는 건 [`docs/operations.md`](operations.md) 의 `data_source: api_only` 진단 절차에서 다룸

`HermesSQLiteWatcher` 도 첫 tick 은 baseline 만 등록하므로 비슷하게 startup burst 는 발생하지 않는다.

---

## 합쳐지는 경로

```swift
// JSONLPoller / HermesSQLiteWatcher → TokenEvent
TokenEvent(provider: .claude or .codex, timestamp, tokens, model, sessionKey)
    ↓ sink callback
DaemonContext { state, hub }.ingestTokenEvent(event)
    ↓
UsageState.ingestTokenEvent(event)
    ↓
BurnTracker.ingest(event, now)  ← 60s sliding window 갱신
    ↓
latestSnapshot = latestSnapshot.with(burn: …)  ← snapshot 에 burn/today 갱신만
    ↓
SSEHub.publishSnapshot(snapshot)  ← 모든 SSE subscriber 에 push
```

(A) 의 quota 데이터는 `latestSnapshot` 의 다른 필드 (5h, 주간, credits) 를 채운다. (B) 의 burn 데이터는 같은 snapshot 의 burn / today 필드만 update. 서로 덮어쓰지 않고 합쳐진다.

---

## 진단: 어느 source 가 살아있나

```sh
# A 가 살아있는가? — quota.weekly.used_pct 가 계속 증가
curl -s -H "Authorization: Bearer $CODEX_TOK" http://127.0.0.1:18910/codex/snapshot \
  | jq '.weekly'

# B 가 살아있는가? — burn / today 가 0 이상
curl -s … | jq '{burn: .burn_rate_per_min, today: .today_total_tokens, sessions: .today_sessions, ds: .status.data_source}'
```

`status.data_source`:
- `api_only` — quota API 만 응답에 들어가 있음. 로컬 watcher 에서 ingest 된 event 가 0
- `api+jsonl` — 로컬 watcher 에서 한 번 이상 event 가 들어옴 (이름은 jsonl 이지만 hermes SQLite ingest 도 같은 flag 를 set)
