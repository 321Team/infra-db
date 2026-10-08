# #47 DB 변경 창 — P1-DB-01 이관 작업 (변경안·창 계획)

책임 티켓: [baseline#47](https://github.com/321Team/fds-project-baseline/issues/47) P2-HYB-01의 "P1-DB-01 이관 작업" 절(Owner 이재환, 위험 수용자 이하영). 관련: [#11](https://github.com/321Team/fds-project-baseline/issues/11) 위험수용(재검토 기한 **2026-10-20 종료 시점**, 자동 연장 없음), [#19](https://github.com/321Team/fds-project-baseline/issues/19) Edge Cutover·DB 자격증명 Residual Risk([6033064018](https://github.com/321Team/fds-project-baseline/issues/19#issuecomment-6033064018)), 일정 제안 [6034620578](https://github.com/321Team/fds-project-baseline/issues/19#issuecomment-6034620578).

이 PR은 **코드·계획 검토용**이다. 병합이나 리뷰 승인은 서버 실행 승인이 아니다. 실행은 Edge Cutover 완료 기록과 이권욱의 서면 GO 뒤에만 한다.

## 1. 범위

| # | 작업 | 호스트 | 도구 | 근거 |
|---|---|---|---|---|
| A | 옛 E-K3S(k3s) 중지·자동 시작 해제 | edge01 | `edge01-k3s.sh` (새) | #47 이관 3번, 9/26 결정 [5843629253](https://github.com/321Team/fds-project-baseline/issues/11#issuecomment-5843629253) |
| B | pg_hba `hostssl fdsdb fds_app 10.1.93.50/32 scram-sha-256` 1줄 제거 | db01 | `db01.sh hba-*` (새) | #47 이관 2번 |
| C | db01 `5432/tcp` 전체 개방 제거, Worker `.105/.107/.108`만 허용 | db01 | [`ops/db01-firewall-5432/apply.sh`](../db01-firewall-5432/apply.sh) (병합 `ab603a9`, 변경 없음) | #47 이관 1번, [infra-db#6](https://github.com/321Team/infra-db/pull/6) |
| D | `fds_app` 비밀번호 교체 + `fds-app/transaction-api-db-credentials` 갱신 + `transaction-api` rollout | control01·db01 | `control01-secret.sh`·`db01.sh pw-*` (새) | #19 Residual Risk ② 6033064018 §3 |

범위 밖: Edge Cutover 자체(edge01 nginx upstream 변경, #19), E-K3S 데이터·바이너리 삭제(uninstall), `robot$fds-ci` 폐기(HBR), `listen_addresses` 변경.

## 2. 전제조건 (하나라도 아니면 시작하지 않음)

1. **Edge Cutover 완료 기록**: edge01 nginx upstream이 Worker `.105/.107/.108:30080`이고 옛 `.50:30080`을 참조하지 않음(`edge01-k3s.sh check`가 다시 확인하고, `stop`은 이 조건이 아니면 멈춘다).
2. 이 PR HEAD의 독립 리뷰(이하영)와 병합. 실행 파일 SHA-256이 병합 commit의 blob과 같음을 실행 기록 첫머리에 남긴다.
3. 이권욱의 창 서면 GO(시각·실행자·중단/복구 한계 포함). 단톡 사전 공지. 다른 창(#10·#13·#15·#19 시험)과 비중첩.
4. 사전 확인(W0)에서: Worker 3대 `transaction-api-nodeport` local endpoint, `transaction-api` 3/3 Ready, Deployment 전략이 maxUnavailable 0(3 replica 기본 25%/25%이면 0)인지, 현재 `DATABASE_URL`이 `postgresql+asyncpg://fds_app:***@10.1.93.55:5432/fdsdb` 형식인지(`control01-secret.sh check`의 sanitized URL). 형식이 다르거나 SSL을 끄는 값(`disable`/`allow`)이 있으면 D는 하지 않고 보고한다.
   - 같은 `check`의 **`fds_app` 사용처 점검**(Secret·ConfigMap 값, 워크로드 spec 리터럴, 이 Secret을 이름으로 참조하는 워크로드. 값은 출력하지 않고 위치만)이 `Secret fds-app/transaction-api-db-credentials DATABASE_URL` 1줄과 `Deployment fds-app/transaction-api (Secret 참조)` 1줄이고 `사용처 점검 rc=0`이어야 한다. 다른 줄이 있거나 rc≠0이면 D는 하지 않고 보고한다(rollout은 transaction-api만 하므로 다른 사용처는 교체 뒤 옛 값으로 인증 실패한다). CronJob이 만든 Job도 별도 줄로 나오므로(Pod만 ownerReferences로 제외) 이런 줄도 "다른 줄"로 보고 D를 하지 않는다(이하영 재리뷰 비차단 메모).
   - 같은 `check`의 `last-applied=`가 `present`이면 그 주석에 현재 값이 들어 있을 수 있다. D의 patch가 같은 요청에서 주석을 지우고 `absent`를 확인한다(`absent`이면 변화 없음). 어느 쪽이든 기록한다.
   - 2026-10-07 18:4x control01 조회(값 가림): `postgresql+asyncpg://fds_app:***@10.1.93.55:5432/fdsdb` — **SSL 파라미터 없음.** asyncpg 기본(prefer)으로 SSL을 협상하고, db01 원격 허용은 `hostssl`뿐이라 평문 연결은 거부된다(앱이 지금 접속 중인 것이 SSL 협상의 근거). D는 비밀번호 부분만 바꾸고 쿼리는 그대로 둔다. `?ssl=require` 명시는 접속 설정 변경이라 이 창에 섞지 않고 후속으로 둔다.
5. db01 `apply.sh check`의 `RUNTIME_PERMANENT_MATCH=YES`(`interfaces:` 줄 제외 비교, `ops/db01-firewall-5432/README.md` 4번), `db01.sh check`의 pg_hba 오류 0·`.50` 대상 줄 1.

## 3. 영향

- **사용자 경로**: edge01 nginx → Worker NodePort는 Cutover 뒤라 A~C와 무관하다. D의 rollout은 maxUnavailable 0·maxSurge 1이라 Ready Pod 수가 줄지 않는다. 새 Pod가 인증에 실패하면 Ready가 되지 않고 rollout이 멈추며 기존 Pod는 남는다.
- **D의 짧은 불일치 구간**: db01 `pw-apply` 뒤 control01 `apply`까지(창 전환 1~2분) 기존 Pod의 **새** DB 연결은 인증에 실패한다. 이미 열린 연결은 끊기지 않고(`ALTER ROLE`은 기존 세션에 영향 없음), `/readyz`는 연결 풀(`pool_pre_ping`)을 쓴다. 풀이 새 연결을 열어야 하는 요청은 이 구간에 503/5xx가 날 수 있다.
- **옛 E-K3S**: A 뒤로 edge01 `.50:30080`과 E-K3S Pod가 사라진다. E-K3S가 쓰던 DB 연결(`pg_stat_activity` `.50`)은 0이 된다. 정본 MON 수집 대상에는 edge01이 없다(infra-monitoring main에 `.50` 대상 없음 — `references/e-k3s`만 해당).
- **운영자 로컬 조회**: D 뒤 `fds_app` 비밀번호를 아는 사람이 없어진다. db01 로컬 조회는 `cd /tmp && sudo -u postgres psql -d fdsdb`(peer)로 한다.
- **MON**: rollout으로 앱 Pod IP가 바뀐다. W5에서 기존 방식으로 count 23·up==0 없음을 확인한다.

## 4. 창 계획 (제안: 10/10(토) 오전 Edge Cutover 뒤 오후, 13:30~14:30 제외)

`RUN`은 세 호스트에서 같은 값(예: `20261010T1500`). 시각은 GO 때 확정한다. 실행자: 이재환(DB Lead·edge01 담당) — GO 때 확정.

| 단계 | 상한 | 호스트 | 명령 | 성공 기준 | 실패 시 |
|---|---|---|---|---|---|
| W0 사전 | 15분 | 4곳 | `edge01-k3s.sh check`, `db01.sh check`, `apply.sh check \| tee ~/p2-hyb01-<RUN>/apply-check-W0.txt`, `control01-secret.sh check`, edge01 `edge01-k3s.sh hba-probe <RUN> allowed`, 음성 시험 N1~N3 **변경 전** 기록 | §2 전제 4·5 충족, db01 `hba_file` 일치=YES, `hba-probe` rc0(ALLOWED — 시험 도구가 이 경로에서 동작함을 먼저 확인), N1~N3 전 결과·도구 존재·출발지 기록, `.50` 세션 수·`fds_app` 사용처·`last-applied` 기록, db01 로그 끄기 SET 사전 시험 rc=0, edge01 reload 반영 판정 rc=0·옛 NodePort ESTABLISHED 연결 수가 숫자 0(`ERR`이면 `ss` 실패) | 시작 안 함 |
| W1 E-K3S 중지 | 10분 | edge01 | `edge01-k3s.sh stop` | 사전 게이트(아래) 통과 후 `RESULT k3s-stop=OK`(k3s inactive·shim 0·`.50:30080` 000·nginx `/readyz` 200), db01 `pg_stat_activity` `.50` = 0 | `edge01-k3s.sh rollback` |
| W2 pg_hba | 5분 | db01 → edge01 | `db01.sh hba-apply` → edge01 `edge01-k3s.sh hba-probe <RUN> rejected` (**W3 전**) | `.50` 출발지 세션 0 확인 후 `RESULT hba-apply=OK`(`pg_reload_conf=t`, 파일 오류 0, `.50` 규칙 0, 재적재 로그 기록) **그리고** `hba-probe` rc0(REJECTED: SQLSTATE 28000 `no pg_hba.conf entry`) | `db01.sh hba-rollback` → `hba-probe <RUN> allowed` rc0 |
| W3 방화벽 | 20분 | db01 → control01 | `apply.sh apply` → control01 `kubectl -n fds-app rollout restart deploy/transaction-api` + `rollout status` | 새 연결 양성(rollout 완료·3/3 Ready·거래 1건 201), 음성 N1~N3 | `apply.sh rollback` |
| W4 비밀번호 | 20분 | control01 → db01 → control01 | `control01-secret.sh prepare` → `db01.sh pw-apply`(검증자 붙여넣기·지문 YES) → `control01-secret.sh apply` | 지문 일치, `RESULT apply=OK`(rollout 완료), 양성 P1·P2 | db01 `pw-rollback` → control01 `rollback` |
| W5 종료 확인 | 15분 | 전체 | 양성·음성 재확인, MON, 각 `check` | 아래 표 전부 기대값 | 원인에 맞는 단계부터 역순 복구 |
| W6 정리 | 5분 | db01·control01 | `db01.sh cleanup`, `control01-secret.sh cleanup` | 비밀 파일 0 | — |

- 전체 상한 T0+90분. 상한을 넘기면 진행 중 단계를 되돌리고 멈춘다(한계 연장 없음). 복구 완료 목표 T0+120분.
- W3에서 현재 비밀번호로 rollout을 한 번 하는 이유: 방화벽·pg_hba 뒤 **새 연결**이 되는지를 비밀번호 교체(W4)와 분리해 확인하기 위함이다. W4가 실패하면 원인을 W4로 좁힐 수 있다.
- W1 `stop` 사전 게이트(하나라도 아니면 k3s를 멈추지 않음): `nginx -t` 성공, `nginx -T`에서 **주석을 지운 유효 설정** 기준 옛 upstream(`.50`/`127.0.0.1`/`localhost`:30080) 0·Worker 3대 3/3, **실행 중 nginx의 reload 반영**(정리 중이 아닌 현재 worker의 **보수적 시작 시각 하한** ≥ `nginx -T`가 읽은 설정 파일들의 나노초 최종 수정 시각. 하한 = `지금 − /proc/uptime + starttime ÷ CLK_TCK − 0.011초`, infra-kubernetes#77 병합 `81ad791d`와 같은 방식. `ps lstart`는 초 버림 오차와 ko_KR 요일·월 이름 해석 실패 때문에 쓰지 않는다), nginx 경유 `/readyz` 5회 호출 뒤 옛 NodePort(`.50`/`127.0.0.1`/`[::1]`:30080)로의 **ESTABLISHED 연결 0**, `/readyz` 200. reload 판정이 1(reload 뒤 설정 변경)이나 2(판단 불가)이면 Edge Cutover 기록·설정 diff를 확인한 뒤 다시 판단한다.
- W2 `hba-apply`는 `.50` 출발지 세션(계정 무관)이 0이 아니면 멈춘다. reload는 기존 연결을 끊지 않으므로 W1에서 E-K3S 연결이 끝났음을 먼저 확인한다.
- W3 선행조건(#9 리뷰 이하영 비차단 2): db01 콘솔 접속이 열려 있고 `apply.sh rollback`을 바로 실행할 수 있어야 한다. `apply`가 reload 뒤 exit 4(인터페이스 바인딩 변경)로 멈추면 permanent 변경은 이미 적용된 상태이므로 즉시 `rollback`을 판단한다.
- W2 적용 확인(#47 리뷰 B1): `pg_reload_conf()`의 `t`는 신호 전송까지, `pg_hba_file_rules`는 **현재 파일 내용**이라 둘 다 실제 적용 증거가 아니다. 그래서 W3(방화벽)로 `.50`이 TCP에서 막히기 **전에** edge01 `hba-probe`로 새 SSL 접속이 pg_hba 단계에서 거부되는지 본다. 이 도구는 SSL 시작 요청과 StartupMessage만 보내고 서버의 첫 응답으로 판정한다(비밀번호를 보내지 않음, 인증 전 종료). ALLOWED(인증 요청)·REJECTED(28000 `no pg_hba.conf entry`) 외의 응답·연결 실패·timeout은 판정 불가(rc4)이며 PASS로 세지 않는다. 판정 불가면 W3로 넘어가지 않는다.
- W4 순서: 검증자 → DB 교체 → Secret·rollout. Secret을 먼저 바꾸면 그 사이 재시작되는 Pod가 실패하므로 DB를 먼저 바꾸고 control01 `apply`를 바로 이어 실행한다.
- W4 `pw-apply` 재실행: 붙여넣기 형식 오류·지문 불일치로 멈춘 뒤 같은 RUN으로 다시 실행하면, 보관한 이전 검증자 사본이 **현재 DB 검증자와 같을 때(= 아직 교체 전)만** 재사용한다. 다르면(이미 교체됨) 멈춘다. 사본은 형식(`SCRAM-SHA-256$4096:…`)을 확인한 뒤에만 쓴다.
- 복구 순서는 역순(W4 → W3 → W2 → W1). E-K3S를 되살려도 `.50` 규칙(W2·W3)과 이전 비밀번호(W4)를 되돌리지 않으면 E-K3S는 DB에 접속하지 못한다(E-K3S Secret은 이전 값).

### 확인 시험

| 구분 | 시험 | 명령(예) | 기대 |
|---|---|---|---|
| P1 | edge 경유 readyz | PC `curl -s -o /dev/null -w '%{http_code}' http://10.1.93.50/readyz` | 200 |
| P2 | 새 거래 저장(단계별) | 아래 "P2 절차" | 단계마다 curl rc0 **그리고** HTTP 201 **그리고** 응답 `transaction_id`, 그 ID와 계정으로 db01 정확히 1행·금액·유형 일치 |
| N1 | 미승인 출발지 control01 | 아래 "N1~N3 절차" (W0 변경 전·W3 뒤 각 1회) | 아래 판정표 |
| N2 | edge01 | 같음 | 같음 |
| N3 | PC(.29) | 같음(Git Bash) | 같음 |
| N4 | fds-engine 직접 | control01 `kubectl -n fds-app exec deploy/fds-engine -- python3 -c "import socket; s=socket.socket(); s.settimeout(5); s.connect(('10.1.93.55', 5432))" ; echo rc=$?` | rc=1이고 오류가 연결 실패(`timed out`·`Connection refused`·`No route to host`). rc=0은 FAIL. rc=126/127(`python3` 없음·실행 불가)이나 exec 자체 실패는 **판정 불가**로 기록하고 다른 방법으로 대체한다 |
| N5 | pg_hba 대조 | `db01.sh check` | `.50` 규칙 0, `.50` 세션 0 |

#### P2 절차 (#47 리뷰 B2)

- 계정은 RUN·단계·시도마다 새로 만든다: `SIM_p2hyb_<RUN에서 T 제외>_W3_1`, `…_W4_1`. 재사용하지 않는다. 과거 회차 행이 있어도 판정에 섞이지 않는다.
- PC(Git Bash), 단계별 응답 파일을 남긴다:
  ```bash
  A=SIM_p2hyb_202610081900_W3_1; O=p2-$A.json
  curl -sS --max-time 10 -o "$O" -w '%{http_code}\n' -X POST http://10.1.93.50/api/v1/transactions -H 'Content-Type: application/json' -d "{\"account_id\":\"$A\",\"amount\":10000,\"transaction_type\":\"deposit\",\"source_ip\":\"198.51.100.10\"}" > "$O.code"; echo "curl_rc=$? http=$(cat "$O.code")"; cat "$O"
  ```
- 성공은 `curl_rc=0` **그리고** `http=201` **그리고** 응답에 `transaction_id`가 있을 때만이다. rc≠0·timeout 등 응답이 불확실하면 **바로 다시 보내지 않고** 먼저 그 계정의 저장 여부를 db01에서 조회한다.
- db01(peer)에서 응답의 ID와 계정으로 정확히 1행을 찾는다. `psql -c`로 넘긴 SQL에는 psql 변수(`:'txid'`)가 치환되지 않으므로 **표준 입력(인용 heredoc)으로** 넣는다(#9 리뷰 B4). 값은 응답·요청에서 옮긴다:
  ```bash
  cd /tmp && sudo -u postgres psql -X -A -d fdsdb -v ON_ERROR_STOP=1 -v txid='<응답 transaction_id>' -v acct='SIM_p2hyb_202610081900_W3_1' <<'SQL'
  SELECT account_id, transaction_id, amount, transaction_type, fds_detected, fds_evaluation_skipped
  FROM transactions
  WHERE transaction_id = :'txid' AND account_id = :'acct';
  SQL
  echo "P2_DB_QUERY_RC=$?"
  ```
  `P2_DB_QUERY_RC=0`은 조회가 실행됐다는 뜻일 뿐이다. 출력 끝의 행 수(`(1 row)`, db01 ko_KR에서는 `(1개 행)`)와 값으로 판정한다. 0행·값 불일치·rc≠0이면 W4나 완료 판정으로 넘어가지 않는다.
  기대: 1행, 금액 10000·`deposit`, `fds_detected`·`fds_evaluation_skipped`가 응답 값과 같음. W3·W4 두 단계를 합치면 이번 RUN 계정 2행이 정상이다.

#### N1~N3 절차 (#47 리뷰 B3)

출발지마다 같은 명령을 **W0(변경 전)과 W3 뒤** 한 번씩 실행해 stdout·stderr·rc를 남긴다. 도구 존재도 함께 기록한다.

```bash
command -v timeout bash; S=$(ip -4 route get 10.1.93.55 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'); echo "src=${S:-?}"; timeout 5 bash -c '</dev/tcp/10.1.93.55/5432'; echo "rc=$?"
```
(PC Git Bash는 `ip`가 없으므로 출발지는 `ipconfig`의 `10.1.93.29`로 기록한다.)

| 관측 | 판정 |
|---|---|
| rc0(TCP 연결 성공) | 차단 **FAIL** — 중단 기준 |
| rc125/126/127, `timeout`·`bash` 없음, 권한·실행 오류 | **판정 불가** — 차단으로 세지 않음 |
| rc124(timeout) 또는 rc1과 `Connection refused`/`No route to host` | 실패 현상만 기록. **변경 전 rc0 → 변경 뒤 실패**로 바뀌었고 db01 규칙(runtime·permanent)과 맞을 때만 이번 통제의 차단 근거로 본다 |
| 변경 전부터 이미 실패(예: control01 timeout, 원인 미확인) | 보호 증거로 세지 않음(#11 위험수용 5989172773). 원인 확인 전까지 판정 불가로 남기고, edge01·PC의 전후 대조와 Worker 새 연결 양성으로 판단한다 |

필요한 관측이 없으면 판정 불가로 남긴다. 검증을 위해 보안 통제를 풀지 않는다.

시험 거래(`SIM_p2hyb_*`)는 기능 시험 거래로 보존한다(#11 결정안 5887795557).

## 5. 앱 갱신 방식 (D)

- 새 비밀번호는 control01에서 `secrets.token_urlsafe(24)`(32자, URL에 그대로 쓸 수 있는 문자)로 만든다. 현재 `DATABASE_URL`의 비밀번호 부분만 바꾸고 scheme·계정·호스트·DB·쿼리는 그대로 둔다.
- db01에는 **SCRAM-SHA-256 검증자**(`SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>`)만 옮긴다. PostgreSQL은 이 형식을 그대로 저장하므로 평문이 db01·DB 로그·화면 전송 경로에 나타나지 않는다. 검증자로는 로그인할 수 없다(ClientKey가 없음). 계산은 실행마다 RFC 7677 예시로 자체 검사한다.
- Secret은 `kubectl patch --type merge --patch-file`(파일 600, 직후 shred)로 `DATABASE_URL` 키만 바꾼다. 라벨·다른 주석·다른 키는 유지된다. 같은 patch에서 `kubectl.kubernetes.io/last-applied-configuration` 주석은 지우고(값이 남을 수 있으므로) patch 뒤 `absent`를 확인한다.
  - `kubectl apply`를 쓰지 않는 이유: client-side apply는 `kubectl.kubernetes.io/last-applied-configuration` 주석에 Secret `data`를 복사해, "값 없는 metadata 조회"에서도 값이 보이게 된다. [infra-kubernetes `scripts/create-secrets-safe.sh`](https://github.com/321Team/infra-kubernetes/blob/main/scripts/create-secrets-safe.sh) `db-url`이 `--dry-run=client -o yaml | kubectl apply -f -`라 이 문제가 있어, 6033064018 §4의 "다음 교체 때 이 스크립트 사용" 대신 이 방식을 쓴다(파일·stdin 전달, xtrace 차단, umask, shred는 같은 원칙). 그 스크립트의 보완은 별도 후속.
- 반영 확인은 값을 보지 않고 한다: Secret 값의 지문(RUN별 무작위 키 HMAC-SHA256 앞 16자, §6)을 준비 파일과 대조하고, rollout 완료·새 Pod Ready(`/readyz`가 DB ping)·P2 거래 저장으로 확인한다. `kubectl exec -- env`는 쓰지 않는다.

## 6. 비밀정보 처리

| 파일 | 위치 | 내용 | 삭제 |
|---|---|---|---|
| `old-url`·`new-url`·`verifier` | control01 `/root/p2-hyb01-<RUN>/secret/`(700/600) | 이전·새 `DATABASE_URL`, 검증자 | W6 `cleanup`(shred) |
| `fpkey` | 같은 control01 폴더 | URL 지문용 RUN 키(32바이트 무작위) | W6 `cleanup`(shred) |
| `fds_app.verifier.before` | db01 `/var/lib/pgsql/fds-evidence/p2-hyb01-<RUN>/`(postgres 700/600) | 이전 검증자(되돌리기용) | W6 `cleanup`(shred) |
| `pg_hba.conf.before/after` | 같은 db01 폴더 | pg_hba 사본(비밀 없음) | 유지 |

- 실행 로그(`~/p2-hyb01-<RUN>/*.log`, control01 `/root/p2-hyb01-<RUN>/*.log`)에는 값이 없다: 지문(16자), sanitized URL(`fds_app:***@`, 마지막 `@` 기준), metadata만 남긴다. 검증자는 control01 터미널(`/dev/tty`)에만 출력하고 로그에 남기지 않는다.
- URL 지문은 평문 SHA-256이 아니라 RUN 키(`fpkey`) HMAC이다. 평문 해시면 증적 로그의 지문으로 이전 비밀번호 추측을 오프라인 확인할 수 있기 때문이다. 키는 W6에서 지우므로 창이 끝난 뒤에는 지문으로 값을 확인할 수 없다. 검증자 지문은 db01과 대조해야 하므로 평문 SHA-256 앞 16자를 쓴다(검증자에 무작위 salt가 있어 비밀번호 추측에 쓰이지 않음).
- **PostgreSQL 서버 로그**: db01 `pw-apply`·`pw-rollback`은 `ALTER ROLE ... PASSWORD`와 같은 psql 세션 앞에서 `log_statement=none`, `log_min_error_statement=panic`, `log_min_duration_statement=-1`, `log_min_duration_sample=-1`, `pg_stat_statements.track_utility=off`를 설정한다(postgres superuser, 그 세션에만 적용). 서버 기본값과 관계없이 검증자 문장이 로그·`pg_stat_statements`에 남지 않게 하기 위함이며, 하나라도 실패하면 `ALTER ROLE` 전에 멈춘다. `check`가 서버의 현재 값(`log_statement`·`log_min_error_statement`·`log_min_duration_statement`)도 기록한다.
- 세 스크립트 모두 xtrace 상태면 시작하지 않는다(`bash -x` 금지). 새 비밀번호는 Secret 밖에 보관하지 않는다.
- cleanup은 W5 종료 판정 직후 같은 창에서 한다. 창이 중단돼 되돌리기 가능성이 남으면 cleanup을 미루고 그 사실을 기록한다.

## 7. 원본 수집

- 각 호스트 로그 폴더 전체: edge01·db01 `~/p2-hyb01-<RUN>/`, control01 `/root/p2-hyb01-<RUN>/*.log`(secret 폴더 제외), PC의 P1~P3 출력.
- 전달: edge01·db01은 PC에서 scp, control01은 파일별 `gzip -9cn | base64 -w 76`과 줄별 `cksum`로 붙여넣기(20KB 이하만, 큰 파일은 서버 SHA만 기록).
- 증적 PR: fds-project-evidence `evidence/P1-DB-01/db-window-<RUN>/`(서버 SHA256SUMS·archive 원본 보존), 독립 리뷰어 지정. #47 결과 코멘트는 증적 PR 링크와 함께 올린다.

## 8. 실행 전 파일 전달

```bash
# PC(Git Bash), 리뷰된 병합 commit 기준으로 전달용 파일을 만든다
git -C infra-db show <MERGE_SHA>:ops/p2-hyb01-db-window/db01.sh > db01.sh && sha256sum db01.sh
```

- 작업 폴더 파일을 그대로 보내지 않는다. 이 PC는 `core.autocrlf=true`라 작업 폴더 사본이 CRLF가 될 수 있다. 위처럼 `git show <MERGE_SHA>:<경로>` 출력으로 만든 파일을 보낸다.
- edge01·db01: PC에서 `scp`로 `edge01-k3s.sh`·`db01.sh`·`apply.sh`(`ops/db01-firewall-5432/`) 전달 후 서버 `sha256sum`이 위 값과 같은지 확인.
- control01: `control01-secret.sh`를 `gzip -9cn | base64 -w 76` 출력에서 옮겨 붙여넣고 복원 후 `sha256sum` 대조.

## 9. 후속 (이 PR 범위 밖)

- `robot$fds-ci`: E-K3S pull secret이 유일한 사용처였다. A 뒤 폐기 여부는 HBR(이하영) 판단.
- E-K3S uninstall·`/var/lib/rancher/k3s` 삭제: 되돌리기 필요가 없어진 뒤 별도 결정.
- infra-kubernetes `create-secrets-safe.sh`의 `kubectl apply` → `patch`/`replace` 보완.
- `DATABASE_URL`에 `?ssl=require` 명시(현재 SSL 파라미터 없음, asyncpg 기본 prefer). create-secrets-safe.sh `db-url`의 SSL 파라미터 필수 규칙과 맞추려면 별도 변경으로 다룬다.
- #47 완료조건(transaction-api 양성, fds-engine·미승인 Client 음성, 전후 firewalld·pg_hba 기록)의 AC 판정은 증적 병합 뒤 DB Lead가 기준·관측 범위를 대조해 판단한다.
