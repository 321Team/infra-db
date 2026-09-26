# db01 5432/tcp 승인 출발지 제한 — 변경안

책임 티켓: P1-DB-01([baseline#11](https://github.com/321Team/fds-project-baseline/issues/11)), IF-04(transaction-api → db01 `.55` TCP 5432, 담당 이재환). 관련: P1-SEC-01([#19](https://github.com/321Team/fds-project-baseline/issues/19)), ICR [#14](https://github.com/321Team/fds-project-baseline/issues/14).

## 현재 상태 (2026-09-25 수집 원본: [evidence#37](https://github.com/321Team/fds-project-evidence/pull/37) `db01/`)

- `listen_addresses = '*'`
- firewalld `public` zone(`ens160`, `ens192`): `ports: 5432/tcp` — **출발지 제한 없음**. rich rule은 SSH 3건뿐.
- `pg_hba.conf`: `fdsdb`/`fds_app`에 대해 `hostssl … scram-sha-256`으로 `.105`/`.107`/`.108`/`.50`만 허용.
- 결과: 인증 전 단계의 호스트 계층 통제가 없어, 승인 밖 출발지도 TCP로는 PostgreSQL까지 도달하고 `pg_hba`에서만 거부된다.

## 변경 (Lead 판단: 승인 출발지로 제한)

| 출발지 | 호스트 | 근거 |
|---|---|---|
| `10.1.93.105` | k8s-worker01 | `kubectl get nodes -o wide` (evidence#37) |
| `10.1.93.107` | k8s-worker02 | 같음 |
| `10.1.93.108` | k8s-worker03 | 같음 |

- transaction-api Pod의 egress는 노드 IP로 SNAT되므로 Worker 3대가 IF-04의 실제 출발지다.
- **`10.1.93.50`(edge01)은 제외한다.** 정본 IF-04는 transaction-api → db01만 승인하고, edge01은 리버스 프록시라 DB 직접 접속 대상이 아니다. `pg_hba`의 `.50` 줄은 edge01 임시 k3s 사전 실증(evidence#2) 때 남은 것이며, P1-SEC-01 Lead가 임시 k3s는 더 이상 필요 없다고 판단했다([리뷰](https://github.com/321Team/infra-db/pull/6)).
- 위 3개에만 `5432/tcp` rich rule을 추가하고, 전체 개방 `port 5432/tcp`를 제거한다. 승인 경로가 끊기지 않도록 rich rule을 먼저 추가한다.
- `listen_addresses`와 `pg_hba`는 바꾸지 않는다(범위 밖).
- db01 자신의 로컬 접속(`127.0.0.1`, 소켓)은 firewalld 영향이 없다.

## 적용 전 조건

1. 이 PR의 HEAD를 작성자 외 적격 검토자가 독립 리뷰한다(실행 설정 변경).
2. 적용 SHA를 고정하고, 리뷰 SHA와의 일치를 실행 기록에 남긴다.
3. `pg_hba` 허용 주소가 위 표(+ 아래 후속 항목의 `.50`)와 여전히 같은지 적용 직전 `check`로 확인한다.
4. `check` 출력의 `RUNTIME_PERMANENT_MATCH=YES`를 확인한다. `--reload`는 runtime 전용 규칙을 지우므로, `NO`이면 차이를 먼저 해소한다(`apply`도 이 경우 변경 없이 중단한다).
5. edge01 뒤의 옛 E-K3S 백엔드가 아직 응답 중이면(9/25 #23 기록) `.50` 차단 후 그 백엔드의 DB 저장이 실패한다. **k3s 정리(중지)와 같은 변경 창에서 적용한다.**

## 절차 (db01, 기존 콘솔 계정)

```bash
sudo -v
bash apply.sh check      # 변경 없음. 현재 상태와 적용 예정 출력
bash apply.sh apply      # 적용 전/후 상태를 함께 출력
```

## 적용 후 확인 (성공 기준)

| 시험 | 명령(예) | 기대 |
|---|---|---|
| 승인 경로 정상 | transaction-api Pod `readyz`, 새 거래 1건 저장 | 200 / 저장 성공 |
| 승인 밖 출발지 차단 | control01(`.102`)에서 `timeout 5 bash -c '</dev/tcp/10.1.93.55/5432' ; echo rc=$?` | rc≠0 (타임아웃 또는 거부) |
| edge01 차단 | edge01(`.50`)에서 같은 명령 | rc≠0 (타임아웃 또는 거부) |
| 대조군 | 같은 호스트에서 db01 SSH 경로 등 기존 허용 경로 | 기존과 동일 |

승인 밖 출발지 차단 결과가 P1-DB-01 AC "미승인 Source 접속이 거부된다"의 근거가 된다. 출력 원본은 fds-project-evidence `evidence/P1-DB-01/`에 편입한다.

## 중단·복구

- 승인 경로 시험이 실패하면 즉시 `bash apply.sh rollback`으로 적용 전 상태(`port 5432/tcp` 전체 개방)로 되돌린다.
- rollback 후 `check` 출력이 적용 전 상태와 같은지 확인한다.

## 후속 (이 PR 범위 밖, DB Lead 추적)

- `pg_hba.conf`의 `hostssl fdsdb fds_app 10.1.93.50/32 scram-sha-256` 줄 제거. 방화벽과 `pg_hba` 허용 목록을 같게 맞추기 위함이며, 같은 변경 창에서 처리하는 것을 권한다.

## 알려진 영향

- Phase 2 IF-18(ROSA → db01 5432)은 현재 목록에 없다. 해당 연동을 시작할 때 출발지 추가를 별도 변경으로 다룬다.
- 새 Worker 노드 추가·IP 변경 시 이 목록과 `pg_hba`를 함께 갱신해야 한다.
