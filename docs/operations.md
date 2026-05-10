# Operations — 배포 / 진단 / 사고 대응

token-run을 producer Mac에서 굴릴 때 자주 쓰는 절차 모음. README는 "어떻게 빌드하고
어떤 architecture인가"에 가깝고, 이 문서는 "동작 안 할 때 무엇부터 보는가" 중심.

---

## 1. 진단 — 무엇이 잘못됐을 때 가장 먼저 보는 것

### 1.1 데몬이 살아있나

```sh
launchctl list | grep token-usage-daemon     # PID + label 보이면 OK
pgrep -f token-usage-daemon                  # 직접 PID 확인
curl -s http://127.0.0.1:18910/healthz       # {"ok":true}
curl -s http://127.0.0.1:18910/version       # name/schema/version
```

`/healthz`가 안 뜨면 데몬이 죽었거나 포트 점유가 빠진 것. launchd plist의 `KeepAlive`
설정상 곧 재기동되어야 한다 (`ThrottleInterval`이 20초).

### 1.2 데몬이 OAuth/quota를 잘 받고 있나

```sh
CLAUDE_TOK=$(jq -r .claude ~/.config/token-usage/tokens.json)
CODEX_TOK=$(jq -r .codex  ~/.config/token-usage/tokens.json)

curl -s -H "Authorization: Bearer $CLAUDE_TOK" http://127.0.0.1:18910/claude/snapshot \
  | jq '{state: .status.state, ds: .status.data_source, weekly: .weekly.used_pct,
         burn: .burn_rate_per_min, today: .today_total_tokens, gen: .generated_at_utc}'

curl -s -H "Authorization: Bearer $CODEX_TOK" http://127.0.0.1:18910/codex/snapshot \
  | jq '{state: .status.state, ds: .status.data_source, weekly: .weekly.used_pct,
         burn: .burn_rate_per_min, today: .today_total_tokens}'
```

`status.state`별 의미:

| state | 의미 | 보통의 원인 |
|---|---|---|
| `ok` | 정상 fetch + 정규화 성공 | — |
| `networkError` | transient (5xx / 429 / 408 / 425 / 네트워크) | 일시적, sticky cache로 600초까진 마지막 OK 데이터 노출 |
| `authExpired` (claude) / `codexLoggedOut` (codex) | refresh-token 거부 또는 401 force-refresh 실패 | 진짜 로그아웃 / refresh token revoke / refresh endpoint 변경 |
| `quotaEndpointChanged` | 4xx 중 401/403/429/408/425/5xx 외 | API 컨트랙트 변경 가능. 앱 업데이트 필요 |

### 1.3 로그

```
/tmp/token-usage-daemon.err.log       # daemon stderr (logger output 포함)
/tmp/token-usage-daemon.out.log       # daemon stdout (Bearer 토큰 첫 생성 시 출력)
~/Library/Logs/token-run-menubar.log  # 메뉴바 앱 SSELog
```

데몬은 SwiftLog `StreamLogHandler.standardError`로 출력. `usage refresh failed` 같은
warning이 보이면 어떤 종류의 에러인지 metadata가 같이 찍힌다.

### 1.4 OAuth credential 직접 점검

```sh
# Claude
jq -r '.claudeAiOauth | {expiresHuman: (.expiresAt/1000 | strftime("%Y-%m-%d %H:%M:%S")), \
       hasAccess: (.accessToken|length>0), hasRefresh: (.refreshToken|length>0)}' \
  ~/.claude/.credentials.json

# Codex
jq -r '.tokens | keys' ~/.codex/auth.json
jq -r '.last_refresh // .lastRefresh' ~/.codex/auth.json
```

권한이 0600이 아니면 다음 daemon refresh가 chmod로 자동 교정한다 (atomic write 후
chmod 0600을 강제). 하지만 처음에 외부 도구가 만든 파일은 0644일 수 있으니 의심되면
직접 `chmod 600`.

### 1.5 OAuth refresh를 직접 한 번 쳐보기 (rate limit / endpoint 의심 시)

```sh
# Claude
REFRESH=$(jq -r '.claudeAiOauth.refreshToken' ~/.claude/.credentials.json)
curl -s -i -X POST https://platform.claude.com/v1/oauth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e" \
  | head -25

# Codex
REFRESH=$(jq -r '.tokens.refresh_token // .tokens.refreshToken' ~/.codex/auth.json)
curl -s -i -X POST https://auth.openai.com/oauth/token \
  -H "Content-Type: application/json" \
  -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$REFRESH\",\"client_id\":\"app_EMoamEEZ73f0CkXaXp7hrann\",\"scope\":\"openid profile email\"}" \
  | head -25
```

| HTTP 응답 | 해석 |
|---|---|
| 200 + `access_token` | refresh 자체는 정상. 데몬 쪽 호출 경로 의심 |
| 400 / 401 / 403 | refresh token 거부됨. 진짜 로그아웃 또는 client_id 변경. claude/codex CLI에서 재로그인 필요 |
| 429 | rate limit. 데몬이 refresh storm 내고 있다는 뜻. 아래 §3.1 참고 |
| 5xx | upstream 일시 장애. sticky cache로 600초까지 버팀 |

---

## 2. 데몬 빌드 / 배포 / 교체

### 2.1 새 빌드 → 배포

```sh
swift build -c release --product token-usage-daemon
launchctl unload ~/Library/LaunchAgents/ai.openclaw.token-usage-daemon.plist
sudo cp .build/release/token-usage-daemon /usr/local/bin/token-usage-daemon
launchctl load ~/Library/LaunchAgents/ai.openclaw.token-usage-daemon.plist
sleep 2 && curl -s http://127.0.0.1:18910/healthz
```

`unload`가 KeepAlive 데몬을 멈추는 유일한 방법이다. `kill`로는 launchd가 곧장 재기동.

### 2.2 launchctl이 말썽일 때

```sh
launchctl unload ~/Library/LaunchAgents/ai.openclaw.token-usage-daemon.plist
pkill -f token-usage-daemon
nohup /usr/local/bin/token-usage-daemon > /tmp/token-usage-daemon.out.log 2>&1 &
disown
```

이 방법은 재부팅 후 사라지므로 영구 해결은 launchd plist + 이슈 원인 진단 필요.

### 2.3 첫 설치

```sh
swift build -c release --product token-usage-daemon
sudo install -m 755 .build/release/token-usage-daemon /usr/local/bin/token-usage-daemon
cp launchd/ai.openclaw.token-usage-daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/ai.openclaw.token-usage-daemon.plist
```

첫 가동 시 `~/.config/token-usage/tokens.json`이 0600으로 자동 생성되고, 그 안의
Bearer 토큰이 stdout에 1회 출력된다. 메뉴바 앱 / 외부 클라이언트가 이 토큰을 사용.

---

## 3. 알려진 사고 패턴

### 3.1 Anthropic 측 429로 claude가 `authExpired`에 박혀있을 때 (2026-04-27 사례)

**증상**:
- `/claude/snapshot` → `state: authExpired`
- 직접 `https://platform.claude.com/v1/oauth/token` 호출하면 `HTTP 429 rate_limit_error`
- 데몬 재시작해도 같은 상태

**원인**:
- 옛날 코드 (cross-process refresh lock 도입 전) 데몬이 60초마다 + SSE 연결마다 refresh
- 동시에 LocalDirectClient + claude-code CLI도 refresh
- 동시 다발 refresh storm → upstream rate limit 발동
- 데몬은 모든 refresh가 reject되니 `authExpired` 송출

**복구**:
1. 데몬 unload (refresh storm 차단 → upstream rate limit window 회복 시작)
2. 5–15분 대기 (cloudflare 429 back-off)
3. 새 코드(cross-process lock + force-refresh + winner adoption 포함)로 빌드 + 교체
4. launchctl load → 한 번의 lock-acquired refresh로 정상화

**예방**:
- `CredentialRefreshLock`을 통과한 새 코드는 같은 사고를 재현하지 않는다 (claude-code CLI가
  같은 lock을 안 쓰지만 우리 쪽 writer 3개는 모두 직렬화됨)
- 의심되면 `tail -f /tmp/token-usage-daemon.err.log`에서 `usage refresh failed` warning 빈도 확인

### 3.2 메뉴바 앱은 정상인데 외부에서 SSE 안 됨

**1차 의심: reverse proxy / tunnel 경로**

```sh
curl -s -i https://your-token-server.example.com/healthz   # 200 + {"ok":true}이어야 함
```

- 502 → tunnel client가 죽었거나 producer가 안 들음. reverse proxy 로그 확인
- 504 → reverse proxy ↔ producer 연결 문제. tunnel/proxy 로그 확인
- DNS 실패 → 원격 endpoint의 DNS / 내부 hosts override 확인

**2차 의심: SSE buffering**

nginx를 쓴다면 `proxy_buffering off`, `X-Accel-Buffering: no`,
`proxy_read_timeout 6h`, `gzip off`이 모두 들어 있어야 한다. 빠지면 SSE가 batch되거나
heartbeat 직전에 끊긴다.

### 3.3 메뉴바 앱이 stale 데이터를 보여준다

- 모드를 한 번 다른 데로 바꿨다가 돌아오면 client가 `await stop()`으로 깨끗이 정리되고
  새 SSE 시작 (mode swap fix 적용 후)
- 그래도 stale이면 daemon snapshot은 정상인지 §1.2로 검증
- daemon은 정상인데 메뉴바만 이상하면 메뉴바 앱 로그 (`~/Library/Logs/token-run-menubar.log`)

### 3.4 계정 전환 후 이전 계정 데이터가 잠깐 보인다

`UsageState`가 이제 `accountKey` (accountID / accountEmail / accessToken tail)로
캐시를 키잉하므로 정상적으로는 일어나지 않아야 함. 만약 발생하면:

- 두 계정의 `accountKey`가 같을 가능성 (token tail 8자리가 일치) — 매우 드묾
- 아니면 회귀. `Sources/TokenUsageCore/State/UsageState.swift`의 `cacheAccountKey`/`lastOkAccountKey` 동작 확인

### 3.5 Anthropic usage endpoint 측 429 (2026-04-28 사례)

**증상**:
- `/claude/snapshot` → `state: ok` 인데 `weekly` / `today` 등 quota 필드 모두 `null`
- daemon log 가 `usage refresh failed error=server(429, …)` 만 반복
- 직접 `https://api.anthropic.com/api/oauth/usage` 를 access token 으로 쳐도 `HTTP 429`

**§3.1 과의 차이**: §3.1 은 OAuth refresh endpoint (`/v1/oauth/token`) 의 429 — 토큰 회전이 막힌 것. 이번 §3.5 는 quota usage endpoint 자체가 429 — 토큰은 정상이지만 사용량 조회가 막힌 것.

**원인**:
- 데몬의 60s 주기 quota refresh 가 transient 429 를 만나면 매분 재시도
- 매 재시도가 cloudflare rate-limit bucket 을 갱신해서 cooldown 이 시작되지 못함
- sticky cache window (600s) 이 만료되면 응답이 빈 quota 로 바뀜

**복구**:
1. `0.10.1+` daemon 으로 교체되어 있으면 (UsageState.fetchSuspendedUntil) 5 분간 자동으로 fetch 정지 → 자가 회복
2. 안 되어 있으면 daemon unload, 5–15 분 대기, 다시 load
3. menubar 앱이 옛날 버전이고 LocalDirect 모드로 같은 endpoint 를 추가로 두드리고 있다면 메뉴바 앱도 0.10.1+ 으로 update

### 3.6 응답에 quota 필드가 `null` 처럼 보이지만 실제로는 데이터가 들어오고 있는 경우

snapshot wire schema 는 `snake_case`. `jq` 조회 시 swift 의 camelCase 필드명으로 검색하면 `null` 이 나와서 데이터 안 들어오는 것처럼 보인다 (실제로는 정상).

```sh
# 잘못된 path (모두 null 로 나옴)
curl … | jq '.burnRatePerMinute, .todayTotalTokens, .todaySessions, .generatedAtUTC'

# 올바른 path
curl … | jq '.burn_rate_per_min, .today_total_tokens, .today_sessions, .generated_at_utc'
```

메뉴바 앱은 `Codable` 의 `CodingKeys` 로 자동 매핑되니 영향 없음. 진단 시에만 주의.

### 3.7 hermes / VSCode codex 사용 중인데 burn rate 가 안 잡힌다

- **hermes agent (`~/.hermes/state.db`)**: `0.10.4+` 데몬은 `HermesSQLiteWatcher` 로 자동으로 잡는다. 30s 주기. session row 의 누적 토큰 delta 를 ingest. 첫 30s 는 baseline 등록만 하고 두 번째 tick 부터 실제 ingest 시작이라 daemon 시작 직후엔 `data_source: api_only` 로 보일 수 있음.
- **VSCode ChatGPT extension (`codex app-server`)**: token usage 를 로컬 파일/DB 에 기록하지 않으므로 burn rate 추적 불가. quota API 측에서 같은 OAuth account 의 사용량으로 합산되므로 `weekly used%` 자체는 정확. burn rate 가 필요하면 codex CLI 또는 hermes 통해서 사용해야 함.

### 3.8 데몬이 starting 메시지만 반복 (옛날 코드 의심)

`/tmp/token-usage-daemon.err.log`가 다음만 반복하면 logger 추가 전 빌드.

```
[info] ai.openclaw.token-usage-daemon: Starting token usage daemon bind=...
```

새 빌드는 실패 시 `usage refresh failed` warning을 metadata와 함께 찍는다. §2.1로 교체.

---

## 4. 메뉴바 앱 빌드 / 배포

```sh
VERSION=0.2.0 GITHUB_REPOSITORY=OWNER/token-terrier GITHUB_RELEASE=1 ./scripts/release.sh
```

흐름:
1. `scripts/make-app.sh`가 host-arch `.app` 번들 생성 + ad-hoc signing
2. `ditto -c -k --keepParent`으로 zip
3. Sparkle `generate_appcast`가 ed25519 서명 + appcast.xml 갱신
4. `GITHUB_RELEASE=1`이면 GitHub Release asset으로 zip/appcast/delta 업로드
5. self-host 또는 migration bridge가 필요하면 `UPLOAD_TARGET`로 rsync

**현재 한계**:
- host-arch only (현재 Apple Silicon 빌드만)
- ad-hoc signing (Developer ID notarization 안 함)

본인 Mac만 쓰는 단계에서는 충분하지만, 외부 배포 시:
- `make-app.sh`에 `lipo`로 universal 빌드 추가
- Developer ID 서명 + `xcrun notarytool` notarization + `xcrun stapler staple`

---

## 5. 메뉴바 앱 측 connection mode 선택 가이드

| 상황 | 권장 모드 |
|---|---|
| 같은 Mac에서 daemon이 도는 일반 케이스 | **자동** (loopback 우선, 실패 시 원격) |
| daemon이 다른 Mac (예: Mac mini producer) | **원격** |
| daemon을 안 띄우고 메뉴바 앱 하나로 끝내고 싶음 | **로컬 직접 read** (메뉴바 앱이 직접 OAuth + JSONL 읽음) |
| 원격 터널 디버깅 / 강제 loopback | **로컬 daemon** |

`로컬 직접 read`는 daemon과 같은 cross-process refresh lock을 통과하므로 daemon과 같이
띄워도 refresh 충돌이 없다.

---

## 6. 빠른 sanity 체크리스트

- [ ] `launchctl list | grep token-usage-daemon` → label 보임
- [ ] `curl http://127.0.0.1:18910/healthz` → `{"ok":true}`
- [ ] `/claude/snapshot`, `/codex/snapshot` → `state: ok`
- [ ] `~/.claude/.credentials.json`, `~/.codex/auth.json` 권한 0600
- [ ] `~/.config/token-usage/tokens.json` 권한 0600
- [ ] `/tmp/token-usage-daemon.err.log` 마지막 1분 안에 warning/error 없음
- [ ] 외부에서 `curl https://your-token-server.example.com/healthz` → 200
