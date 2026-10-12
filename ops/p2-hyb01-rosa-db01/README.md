# #47 db01 — ROSA worker 서브넷 경로 (사전 제한 시험 창 · A2 정식 반영)

책임 티켓: [baseline#47](https://github.com/321Team/fds-project-baseline/issues/47) P2-HYB-01 (Lead 이재환).

근거:
- [§4 확정 입력 6055390599](https://github.com/321Team/fds-project-baseline/issues/47#issuecomment-6055390599)
- [DB 사전 제한 시험 창 제안 6076566493](https://github.com/321Team/fds-project-baseline/issues/47#issuecomment-6076566493)
- #37 터널 selector `10.1.93.0/24 ↔ 10.20.0.0/16`([infra-vpn](https://github.com/321Team/infra-vpn) `p2-vpn-01`)

**이 PR은 코드·절차 검토용입니다.** 병합이나 리뷰 승인은 db01 실행 승인이 아닙니다.
- 사전 창: 이권욱 GO + 이하영 DB 위험 확인이 필요합니다.
- A2: 10/21 창 GO가 필요합니다.

## 바꾸는 것

| 모드 | firewalld | 복귀 경로 | `pg_hba.conf` | 되돌림 |
|---|---|---|---|---|
| `pre-apply` (#37 T3·T6 사전 창) | **runtime만** rich rule 1개 `source 10.20.10.0/24 port 5432/tcp accept` | **runtime만** `10.20.0.0/16 via 10.1.93.51` | 바꾸지 않음(TCP 연결은 pg_hba 전에 성립) | `pre-rollback`. 재부팅·`firewall-cmd --reload`로도 원래대로 돌아감 |
| `a2-apply` (#47 A2) | 같은 rule을 **permanent + reload** | **NM 영구**(`nmcli connection modify +ipv4.routes`) + runtime. connection을 다시 올리지 않음 | `hostssl fdsdb fds_app 10.20.10.0/24 scram-sha-256` 1줄을 마지막 `hostssl fdsdb fds_app` 줄 바로 뒤에 넣고 reload | `a2-rollback`(역순, 부분 적용 상태에서도 실행) |

- **출발지 범위:** `10.20.10.0/24` 하나만 엽니다(§4-1). `/16`, transport, NAT EIP는 허용하지 않습니다. 복귀 경로 범위만 터널 selector와 같은 `/16`입니다.
- **기존 P1 규칙:** Worker `.105/.107/.108` rich rule과 pg_hba 줄은 건드리지 않습니다.
  - a2-apply는 reload 뒤 `pg_hba_file_rules`에서 새 줄을 뺀 나머지의 순서·내용이 전과 같은지 비교합니다. 다르면 멈춥니다.
- **방화벽 비교:** runtime·permanent 비교는 병합된 `ops/db01-firewall-5432/apply.sh check` 결과(`RUNTIME_PERMANENT_MATCH`)를 그대로 씁니다.
  - 두 apply 모드 모두 시작 전에 YES여야 합니다.
  - pre-apply 뒤의 NO는 예상된 값입니다. pre-rollback 뒤 YES로 돌아와야 합니다.
- **pg_hba 쓰기:** db01.sh와 같이 `cat >`로 덮어써 inode·권한·소유자·SELinux 문맥을 유지합니다.
  - 원본 사본은 `/var/lib/pgsql/fds-evidence/p2-hyb01-rosa-<RUN>/`(postgres 700/600)에 둡니다.
  - 같은 RUN으로 다시 적용하지 않습니다.
- **적용 판정의 한계:** `pg_reload_conf()=t`와 `pg_hba_file_rules`는 신호 전송·파일 내용까지만 보여줍니다. 실제 적용은 A4(앱 거래 저장·조회)와 음성 시험으로 판정합니다(10/8 #47 리뷰 B1과 같은 기준).

## 사전 제한 시험 창 (6076566493 W0~W4)

| 단계 | 명령 | 통과 기준 |
|---|---|---|
| W0 | `bash db01-rosa.sh check <RUN>`, `bash ../db01-firewall-5432/apply.sh check` | rule runtime·permanent 모두 absent, 경로 absent, `MATCH=YES`, `10.1.93.51` on-link=YES, `10.20.10.0/24` pg_hba 규칙 0 |
| W1 | `bash db01-rosa.sh pre-apply <RUN>` | `RESULT pre-apply=OK`(rule runtime present / permanent absent, `ip route get 10.20.10.10`이 `via 10.1.93.51`) |
| W2 | (#37) T3·T6. db01: `sudo timeout 120 tcpdump -nni any 'tcp port 5432 and net 10.20.0.0/16'` | T3 출발지 `10.20.10.x`, T6 도달 없음 |
| W3 | `check`의 pg_hba 줄이 W0와 같은지 대조 | `10.20.10.0/24` 규칙 0. 인증 계층 불변 |
| W4 | `bash db01-rosa.sh pre-rollback <RUN>` | `RESULT pre-rollback=OK`(rule·경로 absent, `MATCH=YES`) |
| 상한 | W1~W4 2시간. 넘기면 W2를 멈추고 W4부터 | — |

## A2 (10/21 창, §4-3)

1. `check` — W0와 같은 기준입니다. 사전 창의 runtime rule·경로가 남아 있으면 `pre-rollback`을 먼저 합니다. 다음 두 가지도 기록합니다(infra-db#12 리뷰 비차단 2·3).
   - `NM connection ... ipv4.routes=[...]` 줄의 **실제 nmcli 출력 형식**(metric 포함 여부, 구분자). `nm_has` 판정이 모의 시험 가정과 맞는지 확인합니다. 다르면 a2-apply 전에 멈추고 판정식을 고칩니다.
   - `pg_hba_file_rules`에서 마지막 `hostssl fdsdb fds_app` 줄보다 **앞에 `10.20.10.0/24`를 덮는 reject·다른 매칭 규칙이 없는지**. 있으면 새 줄이 적용되지 않으므로 a2-apply 전에 멈춥니다.
2. `a2-apply`
   - 순서: NM 영구 경로 → runtime 경로 → permanent rule + reload → pg_hba 1줄 + reload
   - 단계마다 readback합니다.
   - reload 뒤 runtime 인터페이스 바인딩이 바뀌면 멈춥니다(apply.sh와 같은 기준).
3. A3·A4는 fds-msa 전환 계약과 [#43 ROSA 전달 계약](https://github.com/321Team/fds-msa/pull/31)을 따릅니다. 판정은 실제 거래 저장·조회입니다.
4. 실패하면 `a2-rollback`을 실행합니다.
   - 순서: pg_hba 사본 복원·reload → permanent rule 제거·reload → NM 경로 제거 → runtime 경로 제거
   - 마지막에 모두 absent이고 `MATCH=YES`인지 확인합니다.
   - **pg_hba SHA 가드**(infra-db#12 리뷰 비차단 1)
     - 현재 `pg_hba.conf`가 a2-apply 결과(`pg_hba.conf.after`)와 같을 때만 사본(`before`)으로 되돌립니다.
     - 이미 `before`와 같으면 복원을 건너뜁니다.
     - 둘 다 아니면 그 사이 다른 pg_hba 변경이 있었을 수 있습니다. 이때는 **덮어쓰지 않고 멈춥니다**(rc 3). 방화벽·경로도 아직 바꾸지 않은 상태라 수동으로 판단합니다.
     - 그래서 a2-rollback은 원칙적으로 같은 작업창 안에서 씁니다.

- **A1 변경점:** #43 전달 계약(fds-msa#31, PROPOSED)에서는 ROSA의 db01 egress를 앱 NetworkPolicy가 아니라 플랫폼 NP `allow-egress-onprem-approved`(infra-rosa#7)와 Pod 라벨 `onprem-egress: "true"`로 엽니다. §4-2 1번("transaction-api NetworkPolicy에 추가")은 그 계약이 확정되면 이 방식으로 읽습니다. db01 쪽 변경은 같습니다.
- **선행:** #37 2단계(터널 SA 수립)와 3단계(AWS route 활성화)가 먼저입니다. db01 경로만 있고 터널이 없으면 `10.20.0.0/16` 응답이 vpn-gw01에서 막힙니다(nft `rt ipsec missing` drop).

## 기록

- 출력: `~/p2-hyb01-rosa-<RUN>/db01-<mode>-<시각>.log`. 비밀 값은 없습니다.
- 증적 위치
  - 사전 창: `evidence/P2-VPN-01/<RUN>/db01/`(#37과 묶음)
  - A2: `evidence/P2-HYB-01/<RUN>/db01/`
- 실행 첫머리에 이 스크립트와 `apply.sh`의 SHA-256이 병합 commit blob과 같은지 기록합니다.

## 시험

```bash
bash ops/p2-hyb01-rosa-db01/tests/test_db01_rosa.sh
```

hostname·sudo·firewall-cmd·ip·nmcli·psql을 가짜로 바꿔 실행합니다. 서버 접속·변경은 없습니다. 판정은 마지막 줄 `FAILS=0`입니다. 확인하는 것:
- 모드별 변경 목록과 순서
- a2-rollback SHA 가드: a2-apply 뒤 pg_hba가 바뀌었으면 덮어쓰지 않고 변경 0으로 멈춤, 이미 원복됐으면 복원 건너뜀
- 이미 있는 rule·경로·NM 경로, runtime·permanent 불일치, 같은 RUN 재적용이면 변경 0으로 멈춤
- a2-apply → a2-rollback 왕복 뒤 pg_hba가 원본과 같음
- pg_hba 삽입 위치(마지막 fds_app 줄 뒤)

**한계 (NOT RUN)**
- 실제 firewalld·NetworkManager·PostgreSQL 동작
- 파일 권한(0700/0600). Windows NTFS에서는 모드 인자를 빼고 실행합니다.
- `DB01_ROSA_TEST_ROOT`는 시험 전용 경로 접두사입니다. 운영에서는 비워 둡니다.
