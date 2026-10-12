#!/usr/bin/env bash
# #47 P2-HYB-01 — ROSA worker 서브넷(private_a 10.20.10.0/24)에서 db01 5432로 오는 경로를 db01에 연다.
# 근거: baseline#47 §4 확정 입력 6055390599, DB 사전 제한 시험 창 제안 6076566493, #37 터널 selector 10.20.0.0/16.
# 사용: sudo -v 후 `bash db01-rosa.sh <mode> <RUN>`   (RUN 예: 20261021T1000)
#   check        : 변경 없음. 방화벽(runtime·permanent)·복귀 경로(runtime·NM 설정)·pg_hba 상태와 적용 예정 내용
#   pre-apply    : 사전 제한 시험 창(#37 T3·T6). **runtime만** rich rule 1개 + 복귀 경로 1개. pg_hba·permanent 불변.
#                  W0 기준선과 단계별 INTENT/DONE을 RUN receipt(~/p2-hyb01-rosa-<RUN>/pre.receipt)에 남긴다
#   pre-rollback : 같은 RUN receipt에 적힌 변경만 원복하고 W0와 대조한다. receipt가 없거나 이 RUN이 넣지 않은 항목은
#                  지우지 않고 멈춘다(수동 판단). firewalld reload는 runtime rule만 permanent로 되돌리고 커널 경로는
#                  지우지 않는다. 재부팅은 정리 수단이 아니다. 2시간 상한은 자동 만료가 아니다(infra-db#12 권욱 B1·B3)
#   a2-apply     : #47 A2 정식 반영(10/21 창). 복귀 경로(runtime + NM 영구) → rich rule(permanent + reload)
#                  → pg_hba 1줄(`hostssl fdsdb fds_app 10.20.10.0/24 scram-sha-256`, 기존 fds_app hostssl 줄 바로 뒤) + reload
#   a2-rollback  : a2-apply 원복(pg_hba 사본 복원 → rich rule 제거 + reload → 경로 삭제). 부분 적용 상태에서도 실행한다
#   render-hba <in> <out> : 서버 없이 pg_hba 삽입 결과만 만든다(시험·리뷰용, RUN 불필요)
# 출력 기록은 ~/p2-hyb01-rosa-<RUN>/, pg_hba 사본은 postgres 소유 /var/lib/pgsql/fds-evidence/p2-hyb01-rosa-<RUN>/(700/600).
# set -e는 쓰지 않는다. 단계마다 결과를 보고 멈춘다. 이 스크립트 병합은 실행 GO가 아니다.
set -uo pipefail

ZONE=public
PORT=5432
SRC=10.20.10.0/24          # 승인 출발지 최소 집합(#47 §4-1). /16·transport·NAT EIP는 허용하지 않는다
TUN=10.20.0.0/16           # 복귀 경로 범위 = #37 터널 selector
GW=10.1.93.51              # vpn-gw01
PROBE=10.20.10.10          # 경로 확인용 주소(private_a 안)
HBA_LINE="hostssl fdsdb fds_app $SRC scram-sha-256"
HBA_RE='^hostssl[[:space:]]+fdsdb[[:space:]]+fds_app[[:space:]]+10\.20\.10\.0/24[[:space:]]+scram-sha-256[[:space:]]*$'
ANCHOR_RE='^hostssl[[:space:]]+fdsdb[[:space:]]+fds_app[[:space:]]'
RULE="rule family=\"ipv4\" source address=\"$SRC\" port port=\"$PORT\" protocol=\"tcp\" accept"
# DB01_ROSA_TEST_ROOT: 모의 시험 전용 경로 접두사(tests/). 운영에서는 비워 둔다.
TROOT=${DB01_ROSA_TEST_ROOT:-}
PGDATA=$TROOT/var/lib/pgsql/data
HBA=$PGDATA/pg_hba.conf
HERE=$(cd "$(dirname "$0")" && pwd)
FW_TOOL=$HERE/../db01-firewall-5432/apply.sh

# pg_hba 삽입: 마지막 `hostssl fdsdb fds_app` 줄 바로 뒤에 1줄. 기준 줄이 없으면 rc3, 이미 있으면 rc4.
render_hba() {
  grep -qE "$HBA_RE" "$1" && return 4
  awk -v add="$HBA_LINE" -v re="$ANCHOR_RE" '
    { line[NR] = $0 } $0 ~ re { last = NR }
    END { if (!last) exit 3; for (i = 1; i <= NR; i++) { print line[i]; if (i == last) print add } }' "$1" > "$2"
}

MODE=${1:-}
if test "$MODE" = render-hba; then
  test $# = 3 || { echo "usage: bash $0 render-hba <in> <out>" >&2; exit 2; }
  render_hba "$2" "$3"; rc=$?
  case $rc in 0) echo "RESULT render-hba=OK" ;; 3) echo "STOP: 기준 줄(hostssl fdsdb fds_app ...) 없음" ;; 4) echo "STOP: 같은 줄이 이미 있음" ;; esac
  exit $rc
fi

RUN=${2:-}
case "$RUN" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9]) ;;
  *) echo "usage: bash $0 check|pre-apply|pre-rollback|a2-apply|a2-rollback <RUN=yyyymmddTHHMM> | render-hba <in> <out>" >&2; exit 2 ;;
esac
test "$(hostname -s)" = db01 || { echo "STOP: db01이 아님" >&2; exit 2; }
case "$-" in *x*) echo "STOP: xtrace 상태로 실행 금지" >&2; exit 2 ;; esac

SEC=$TROOT/var/lib/pgsql/fds-evidence/p2-hyb01-rosa-$RUN
LOGDIR=$HOME/p2-hyb01-rosa-$RUN
mkdir -p "$LOGDIR" && chmod 700 "$LOGDIR" || { echo "STOP: $LOGDIR 생성 실패" >&2; exit 2; }
LOG=$LOGDIR/db01-$MODE-$(date +%H%M%S).log
# 사전 창 RUN receipt: W0 기준선 1줄 + 단계별 INTENT/DONE. 원복은 여기 적힌 변경만 한다(B3).
RCPT=$LOGDIR/pre.receipt
exec > >(tee -a "$LOG") 2>&1

die() { echo "STOP: $*"; exit 3; }
pg() { (cd /tmp && sudo -u postgres psql -X -q -A -t -v ON_ERROR_STOP=1 -d fdsdb "$@"); }

# 0=있음, 1=없음, 2=조회 실패. firewall-cmd --query-*는 yes→0, no→1을 돌려준다.
fw_has() { # [--permanent]
  local rc=0
  sudo firewall-cmd "$@" --zone="$ZONE" --query-rich-rule="$RULE" >/dev/null 2>&1 || rc=$?
  case $rc in 0|1) return $rc ;; *) return 2 ;; esac
}
fw_state() { local r=0; fw_has "$@" || r=$?; case $r in 0) echo present ;; 1) echo absent ;; *) echo QUERY_ERROR ;; esac; }
# 검토된 apply.sh check의 runtime·permanent 비교(interfaces 줄 제외, rich rule 순서 무시)를 그대로 쓴다.
fw_match() { bash "$FW_TOOL" check 2>&1 | sed -n 's/^RUNTIME_PERMANENT_MATCH=\([A-Z_]*\).*/\1/p' | head -1; }
rt_ifaces() { sudo firewall-cmd --zone="$ZONE" --list-interfaces | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }

route_rt() { ip -4 route show exact "$TUN"; }
route_state() { local r; r=$(route_rt) || { echo QUERY_ERROR; return; }; test -n "$r" && echo "present [$r]" || echo absent; }
gw_dev() { ip -4 -o route get "$GW" | sed -n 's/.* dev \([^ ]*\).*/\1/p'; }
# 파이프 끝 grep -q가 먼저 끝나면 앞 명령이 SIGPIPE로 실패해 pipefail에 걸리므로, 출력을 변수로 받아 판정한다.
gw_onlink() { local r; r=$(ip -4 -o route get "$GW") || return 2; case "$r" in *" via "*) return 1 ;; esac; return 0; }
via_gw() { local r; r=$(ip -4 -o route get "$PROBE") || return 2; case "$r" in *" via $GW "*) return 0 ;; esac; return 1; }
nm_conn() { local d; d=$(gw_dev) && test -n "$d" && nmcli -g GENERAL.CONNECTION device show "$d"; }
nm_routes() { nmcli -g ipv4.routes connection show "$1"; }
# 0=있음, 1=없음, 2=조회 실패. 호출하는 쪽은 `!`로 뒤집지 말고 세 값을 나눠 판정한다(infra-db#12 권욱 B4).
nm_has() {
  local r; r=$(nm_routes "$1") || return 2
  test "$(printf '%s\n' "$r" | tr ',' '\n' | sed 's/^ *//' | grep -cE "^${TUN//./\\.} ${GW//./\\.}( |$)")" -gt 0
}
nm_state() { test -n "$1" || { echo CONN_UNKNOWN; return; }; local r=0; nm_has "$1" || r=$?; case $r in 0) echo present ;; 1) echo absent ;; *) echo QUERY_ERROR ;; esac; }
# runtime rich rule 목록(정렬) 해시. W0와 원복 뒤를 비교한다. 조회 실패면 rc≠0.
fw_rules_sha() { local r; r=$(sudo firewall-cmd --zone="$ZONE" --list-rich-rules) || return 2; printf '%s\n' "$r" | sort | sha256sum | cut -c1-64; }

hba_errors() { pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL"; }
hba_new_rows() { pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE address = '10.20.10.0' AND netmask = '255.255.255.0'"; }
hba_rules() { pg -c "SELECT line_number, type, array_to_string(database,','), array_to_string(user_name,','), coalesce(address,''), coalesce(netmask,''), auth_method FROM pg_hba_file_rules ORDER BY line_number"; }
# 10.20.10.x 출발지에 매칭될 수 있는 허용 줄(reject 제외). exact 줄뿐 아니라 all·samenet·samehost, 이 대역을
# 포함하거나 이 대역 안에 있는 IPv4 CIDR, 호스트 이름 줄(판정 불가 → 보수적으로 포함)을 모두 낸다.
# 사전 창은 인증 경로를 열지 않아야 하므로 하나라도 있으면 멈춘다(#47 6116037629 하영 조건 1).
HBA_BROAD_SQL="SELECT line_number || ' ' || type || ' ' || array_to_string(database,',') || ' ' || array_to_string(user_name,',') || ' ' || coalesce(address,'') || ' ' || coalesce(netmask,'') || ' ' || auth_method
FROM pg_hba_file_rules
WHERE error IS NULL AND type LIKE 'host%' AND auth_method <> 'reject' AND (
  address IN ('all','samenet','samehost')
  OR (address ~ '^[0-9.]+\$' AND netmask ~ '^[0-9.]+\$' AND (
       (inet '10.20.10.0' & netmask::inet) = (address::inet & netmask::inet)
       OR address::inet << inet '10.20.10.0/24'))
  OR (address !~ '^[0-9.:]+\$' AND address NOT IN ('all','samenet','samehost')))
ORDER BY line_number"
hba_broad() { pg -c "$HBA_BROAD_SQL"; }
# 인증 전 연결도 backend 슬롯을 쓰므로 창 전후 여유를 기록한다(하영 조건 2).
conn_headroom() { pg -c "SELECT 'max_connections=' || current_setting('max_connections') || ' superuser_reserved=' || current_setting('superuser_reserved_connections') || ' sessions=' || (SELECT count(*) FROM pg_stat_activity) || ' authentication_timeout=' || current_setting('authentication_timeout')"; }
hba_file_ok() { test "$(pg -c 'SHOW hba_file')" = "$HBA"; }
# db01.sh와 같은 기준: pg_reload_conf()는 신호 전송 결과 t일 때만 통과. 실제 적용 판정은 아니다.
reload_pg() { local s; s=$(pg -c "SELECT pg_reload_conf()") || die "pg_reload_conf SQL 실패"; test "$s" = t || die "pg_reload_conf 결과 '$s'"; sleep 2; echo "-- pg_reload_conf=t ($(date '+%T'))"; }

show() {
  echo "== $(date '+%F %T %Z') db01 mode=$MODE run=$RUN"
  echo "-- rich rule [$RULE]: runtime=$(fw_state) permanent=$(fw_state --permanent)"
  echo "-- apply.sh 비교 RUNTIME_PERMANENT_MATCH=$(fw_match)"
  echo "-- runtime interfaces=[$(rt_ifaces)]"
  echo "-- 복귀 경로 $TUN: runtime=$(route_state)"
  echo "-- ip route get $PROBE: $(ip -4 -o route get "$PROBE" 2>&1)"
  echo "-- ip route get $GW: $(ip -4 -o route get "$GW" 2>&1) (on-link=$(gw_onlink && echo YES || echo NO))"
  local c; c=$(nm_conn) || c=""
  echo "-- NM connection(dev $(gw_dev))=[$c] ipv4.routes=[$(test -n "$c" && nm_routes "$c")] 영구 경로=$(nm_state "$c")"
  echo "-- runtime rich rule 목록 sha256: $(fw_rules_sha || echo QUERY_ERROR)"
  if test -f "$RCPT"; then
    local t0; t0=$(sed -n 's/^W0 \([0-9]*\) .*/\1/p' "$RCPT")
    echo "-- RUN receipt: $(grep -c . "$RCPT")줄, W1 기준 $(date -d "@$t0" '+%T') 경과 $(( ($(date +%s) - t0) / 60 ))분 / 상한 120분(자동 만료 아님)$(grep -q '^DONE rollback' "$RCPT" && echo ', 원복 완료 기록 있음')"
  fi
  echo "-- pg_hba.conf sha256: $(sudo sha256sum "$HBA" | cut -d' ' -f1)  대상 줄 수(파일): $(sudo grep -cE "$HBA_RE" "$HBA")"
  echo "-- 서버 hba_file 일치=$(hba_file_ok && echo YES || echo NO), pg_hba_file_rules 오류=$(hba_errors), $SRC 규칙=$(hba_new_rows)"
  echo "-- $TUN 출발지 세션 수: $(pg -c "SELECT count(*) FROM pg_stat_activity WHERE client_addr << '$TUN'")"
  echo "-- 연결 여유: $(conn_headroom)"
  local b; b=$(hba_broad) || b=QUERY_ERROR
  echo "-- 10.20.10.x에 매칭될 수 있는 pg_hba 허용 줄(넓은 범위 포함, reject 제외): $(test -z "$b" && echo 없음 || printf '%s' "$b" | grep -c .)"
  test -z "$b" || printf '%s\n' "$b" | sed 's/^/   /'
}
# 실행 환경 기록(권욱 리뷰 증적 항목): 이 스크립트·apply.sh 파일 SHA, db01 identity, 도구·서버 버전, main 경로표 해시.
# 병합 commit blob과의 대조는 실행자가 기록한다(README "기록"). 조회 실패는 그대로 출력한다.
env_record() {
  echo "== 실행 환경"
  echo "-- script sha256: db01-rosa.sh=$(sha256sum "$HERE/db01-rosa.sh" | cut -c1-64) apply.sh=$(sha256sum "$FW_TOOL" 2>/dev/null | cut -c1-64)"
  echo "-- identity: hostname=$(hostname -f 2>&1) zone=$ZONE interfaces=[$(rt_ifaces)] gw_dev=$(gw_dev)"
  echo "-- versions: firewalld=$(sudo firewall-cmd --version 2>&1) iproute=$(ip -V 2>&1) nmcli=$(nmcli --version 2>&1 | head -1) postgres=$(pg -c 'SHOW server_version' 2>&1)"
  echo "-- ip -4 route show table main sha256: $(ip -4 route show table main | sha256sum | cut -c1-64)"
}
# 사전 창 쓰기 전 가드. 필수 조회마다 RC와 값을 따로 본다. 실패·빈값·불일치면 사유를 내고 1(infra-db#12 권욱 B2).
# check는 같은 함수로 W0_READY를 출력하고, pre-apply는 이 함수가 통과해야만 첫 쓰기를 한다.
pre_guard() {
  local v c
  test "$(fw_match)" = YES || { echo "RUNTIME_PERMANENT_MATCH가 YES가 아님(조회 실패 포함)"; return 1; }
  test "$(fw_state)" = absent && test "$(fw_state --permanent)" = absent || { echo "rich rule이 이미 있거나 조회 실패"; return 1; }
  test "$(route_state)" = absent || { echo "복귀 경로가 이미 있거나 조회 실패"; return 1; }
  gw_onlink || { echo "$GW가 직접 연결(on-link) 경로가 아니거나 조회 실패"; return 1; }
  hba_file_ok || { echo "서버 hba_file이 $HBA 가 아니거나 조회 실패"; return 1; }
  v=$(hba_errors) || { echo "pg_hba 오류 수 조회 실패"; return 1; }
  test "$v" = 0 || { echo "pg_hba_file_rules 오류 [$v]"; return 1; }
  v=$(hba_new_rows) || { echo "pg_hba $SRC 규칙 조회 실패"; return 1; }
  test "$v" = 0 || { echo "$SRC pg_hba 규칙이 이미 있음 [$v]"; return 1; }
  v=$(hba_broad) || { echo "pg_hba 매칭 줄 조회 실패"; return 1; }
  test -z "$v" || { echo "10.20.10.x에 매칭되는 pg_hba 허용 줄이 이미 있음(위 목록) — 인증 경로가 열린 상태"; return 1; }
  v=$(hba_rules) && test -n "$v" || { echo "pg_hba_file_rules 원문 조회 실패"; return 1; }
  v=$(conn_headroom) && test -n "$v" || { echo "연결 여유 조회 실패"; return 1; }
  c=$(nm_conn) && test -n "$c" || { echo "NM connection 조회 실패"; return 1; }
  case "$(nm_state "$c")" in absent) ;; present) echo "NM 영구 경로가 이미 있음"; return 1 ;; *) echo "NM 영구 경로 조회 실패"; return 1 ;; esac
  v=$(fw_rules_sha) && test -n "$v" || { echo "runtime rich rule 목록 조회 실패"; return 1; }
  return 0
}
# 사전 조건: 매칭 허용 줄이 없어야 한다. 조회 실패도 멈춘다.
need_no_broad() {
  local b; b=$(hba_broad) || die "pg_hba 매칭 줄 조회 실패. 변경하지 않았다"
  test -z "$b" || die "10.20.10.x에 매칭되는 pg_hba 허용 줄이 이미 있음(위 목록) — 인증 경로가 열린 상태라 변경하지 않았다"
}

case "$MODE" in
  check)
    sudo -v || die "sudo 인증 실패"
    env_record
    show
    echo "-- pg_hba_file_rules"; hba_rules || echo "-- pg_hba_file_rules 조회 실패"
    # rc0은 "조회를 마쳤다"는 뜻일 뿐이다. 사전 창 시작 가능 여부는 이 줄로 본다(B2).
    r=$(pre_guard) && echo "W0_READY(pre-apply)=YES" || echo "W0_READY(pre-apply)=NO — $r"
    echo "== 적용 예정"
    echo "pre-apply : runtime + $RULE / ip route add $TUN via $GW (pg_hba 불변)"
    echo "a2-apply  : 위 경로를 NM 영구 + runtime, rule permanent + reload, pg_hba 줄 '$HBA_LINE' 삽입"
    ;;

  pre-apply)
    sudo -v || die "sudo 인증 실패"
    test -e "$RCPT" && die "이 RUN의 receipt가 이미 있음($RCPT). 같은 RUN으로 다시 적용하지 않는다 — 새 RUN을 쓴다"
    env_record
    show
    r=$(pre_guard) || die "$r. 변경하지 않았다"
    W0_RULES=$(fw_rules_sha) || die "runtime rich rule 목록 조회 실패. 변경하지 않았다"
    T0=$(date +%s)
    # W0 기준선. 이 줄을 못 쓰면 원복 근거가 없으므로 쓰기 전에 멈춘다.
    echo "W0 $T0 $(date '+%F %T') rule_rt=absent rule_perm=absent route=absent match=YES rules_sha=$W0_RULES" > "$RCPT" \
      || die "receipt 기록 실패. 변경하지 않았다"
    echo "-- W1 $(date -d "@$T0" '+%T') / 마지막 시험 시작 ≤ $(date -d "@$((T0 + 90*60))" '+%T') / W4 시작 ≤ $(date -d "@$((T0 + 100*60))" '+%T') / 완료 상한 $(date -d "@$((T0 + 120*60))" '+%T') — 자동 만료 아님, 카드대로 pre-rollback"
    echo "INTENT rule" >> "$RCPT" || die "receipt 기록 실패. 변경하지 않았다"
    sudo firewall-cmd --zone="$ZONE" --add-rich-rule="$RULE" || die "runtime rule 추가 실패 → pre-rollback $RUN"
    echo "DONE rule" >> "$RCPT"
    echo "INTENT route" >> "$RCPT" || die "receipt 기록 실패(rule만 추가된 상태) → pre-rollback $RUN"
    sudo ip route add "$TUN" via "$GW" || die "경로 추가 실패(rule만 추가된 상태) → pre-rollback $RUN"
    echo "DONE route" >> "$RCPT"
    show
    test "$(fw_state)" = present && test "$(fw_state --permanent)" = absent || die "rule readback 불일치 → pre-rollback $RUN"
    via_gw || die "$PROBE 경로가 $GW를 지나지 않음 → pre-rollback $RUN"
    echo "RESULT pre-apply=OK $(date '+%T') — runtime만 변경. MATCH=NO는 이 창에서 예상된 값이다(pre-rollback 뒤 YES여야 함)"
    ;;

  pre-rollback)
    sudo -v || die "sudo 인증 실패"
    show
    # 이 RUN이 기록한 변경만 되돌린다. receipt가 없으면 아무것도 지우지 않는다(B3).
    test -f "$RCPT" && grep -q '^W0 ' "$RCPT" \
      || die "이 RUN($RUN)의 pre-apply receipt가 없음 — 이 RUN이 넣은 변경이 아니므로 지우지 않았다. 수동 판단"
    W0_RULES=$(sed -n 's/^W0 .* rules_sha=\([0-9a-f]*\).*/\1/p' "$RCPT")
    FOREIGN=""
    # 1) rule: INTENT가 있으면 이 RUN 소유. 조회 실패는 원복 완료 판정을 막는다.
    ST=$(fw_state)
    if grep -qx 'INTENT rule' "$RCPT"; then
      case "$ST" in
        present) sudo firewall-cmd --zone="$ZONE" --remove-rich-rule="$RULE" || die "runtime rule 삭제 실패 — 수동 판단(경로는 아직 그대로)" ;;
        absent) echo "-- rule: 이미 없음(예: firewalld reload) — 건너뜀" ;;
        *) die "rule 조회 실패 — 원복 완료 판정 금지(경로는 아직 그대로)" ;;
      esac
    else
      test "$ST" = absent || FOREIGN="$FOREIGN rule($ST)"
    fi
    # 2) 경로: firewalld reload로는 지워지지 않는다. INTENT가 있고 via $GW인 정확한 경로만 지운다.
    ST=$(route_state)
    if grep -qx 'INTENT route' "$RCPT"; then
      case "$ST" in
        absent) echo "-- 경로: 이미 없음 — 건너뜀" ;;
        "present ["*" via $GW "*) sudo ip route del "$TUN" via "$GW" || die "경로 삭제 실패 — 수동 판단" ;;
        present*) FOREIGN="$FOREIGN route($ST)" ;;
        *) die "경로 조회 실패 — 원복 완료 판정 금지" ;;
      esac
    else
      test "$ST" = absent || FOREIGN="$FOREIGN route($ST)"
    fi
    show
    test -z "$FOREIGN" || die "이 RUN이 넣지 않은 항목이 있어 지우지 않았다:$FOREIGN — 이 RUN 소유분만 정리함. 수동 판단"
    test "$(fw_state)" = absent && test "$(fw_state --permanent)" = absent && test "$(route_state)" = absent \
      || die "원복 readback에 rule 또는 경로가 남거나 조회 실패"
    test "$(fw_match)" = YES || die "원복 뒤 RUNTIME_PERMANENT_MATCH가 YES가 아님 — W0 기록과 대조"
    # runtime=permanent만으로 W0 복원이라 단정하지 않는다. W0 runtime rich rule 목록과 같아야 한다.
    NOW_RULES=$(fw_rules_sha) || die "runtime rich rule 목록 조회 실패 — 원복 완료 판정 금지"
    test -n "$W0_RULES" && test "$NOW_RULES" = "$W0_RULES" || die "runtime rich rule 목록이 W0와 다름(W0=${W0_RULES:-없음} 현재=$NOW_RULES) — 수동 대조"
    echo "DONE rollback $(date +%s) $(date '+%F %T')" >> "$RCPT"
    echo "RESULT pre-rollback=OK $(date '+%T') — W0 대조 일치"
    ;;

  a2-apply)
    sudo -v || die "sudo 인증 실패"
    env_record
    show
    echo "-- pg_hba_file_rules(전)"; hba_rules | tee "$LOGDIR/hba-rules.before" || die "pg_hba_file_rules 조회 실패. 변경하지 않았다"
    test "$(fw_match)" = YES || die "RUNTIME_PERMANENT_MATCH가 YES가 아님. 변경하지 않았다"
    test "$(fw_state)" = absent && test "$(fw_state --permanent)" = absent || die "rich rule이 이미 있음(pre-apply가 남았으면 pre-rollback 먼저). 변경하지 않았다"
    test "$(route_state)" = absent || die "runtime 복귀 경로가 이미 있음. 변경하지 않았다"
    gw_onlink || die "$GW가 직접 연결 경로가 아님. 변경하지 않았다"
    CONN=$(nm_conn) && test -n "$CONN" || die "$GW 경로의 NM connection을 찾지 못함. 변경하지 않았다"
    case "$(nm_state "$CONN")" in
      absent) ;;
      present) die "NM 영구 경로가 이미 있음. 변경하지 않았다" ;;
      *) die "NM 영구 경로 조회 실패. 변경하지 않았다" ;;
    esac
    hba_file_ok || die "서버 hba_file이 $HBA 가 아님. 변경하지 않았다"
    test "$(hba_errors)" = 0 || die "적용 전 pg_hba_file_rules 오류. 변경하지 않았다"
    test "$(hba_new_rows)" = 0 || die "$SRC 규칙이 이미 있음. 변경하지 않았다"
    need_no_broad
    sudo -u postgres mkdir -p -m 700 "$SEC" || die "$SEC 생성 실패. 변경하지 않았다"
    sudo -u postgres test -e "$SEC/pg_hba.conf.before" && die "이전 사본이 이미 있음. 같은 RUN으로 재적용하지 않는다"
    sudo -u postgres cp -p "$HBA" "$SEC/pg_hba.conf.before" || die "사본 저장 실패. 변경하지 않았다"
    # 후보 파일은 사본에서 만들고, 1줄만 늘었는지 먼저 확인한다(아직 서버 변경 없음).
    sudo -u postgres bash -c "$(declare -f render_hba); HBA_RE='$HBA_RE'; ANCHOR_RE='$ANCHOR_RE'; HBA_LINE='$HBA_LINE'; umask 077; render_hba \"\$1\" \"\$2\"" \
      _ "$SEC/pg_hba.conf.before" "$SEC/pg_hba.conf.after" || die "pg_hba 후보 생성 실패(기준 줄 없음 또는 이미 있음). 변경하지 않았다"
    # diff는 다르면 rc1이다. pipefail 아래에서 파이프로 바로 grep하면 성공도 실패가 되므로 출력을 먼저 받는다.
    HDIFF=$(sudo diff "$SEC/pg_hba.conf.before" "$SEC/pg_hba.conf.after"); test $? = 1 || die "후보가 원본과 같거나 diff 실패. 변경하지 않았다"
    echo "-- pg_hba 후보 diff:"; printf '%s\n' "$HDIFF"
    test "$(printf '%s\n' "$HDIFF" | grep -c '^[<>]')" = 1 && test "$(printf '%s\n' "$HDIFF" | grep -cxF "> $HBA_LINE")" = 1 \
      || die "후보가 1줄 추가가 아님. 변경하지 않았다"
    IF_BEFORE=$(rt_ifaces)

    # 1) 복귀 경로: NM 영구 설정(재부팅 대비) + runtime. connection을 다시 올리지 않는다(기존 연결 끊김 방지).
    nm_routes "$CONN" > "$LOGDIR/nm-routes.before"
    sudo nmcli connection modify "$CONN" +ipv4.routes "$TUN $GW" || die "NM 영구 경로 추가 실패 → a2-rollback"
    nm_has "$CONN" || die "NM 영구 경로 readback 실패 → a2-rollback"
    sudo ip route add "$TUN" via "$GW" || die "runtime 경로 추가 실패 → a2-rollback"
    via_gw || die "$PROBE 경로가 $GW를 지나지 않음 → a2-rollback"
    # 2) 방화벽: permanent + reload(runtime 전용 규칙이 없음을 위에서 확인했다)
    sudo firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE" || die "permanent rule 추가 실패 → a2-rollback"
    sudo firewall-cmd --reload || die "firewalld reload 실패 → a2-rollback"
    test "$(rt_ifaces)" = "$IF_BEFORE" || die "reload 뒤 runtime 인터페이스 바인딩이 바뀜 → a2-rollback 판단"
    test "$(fw_state)" = present && test "$(fw_state --permanent)" = present || die "rule readback 불일치 → a2-rollback"
    test "$(fw_match)" = YES || die "reload 뒤 MATCH가 YES가 아님 → a2-rollback"
    # 3) pg_hba: cat > 로 덮어써 inode·권한·소유자·SELinux 문맥을 유지한다(db01.sh와 같은 방식).
    sudo -u postgres sh -c 'cat "$1" > "$2"' sh "$SEC/pg_hba.conf.after" "$HBA" || die "pg_hba.conf 쓰기 실패 → a2-rollback"
    reload_pg
    echo "-- pg_hba_file_rules(후)"; hba_rules | tee "$LOGDIR/hba-rules.after" || die "pg_hba_file_rules 조회 실패 → a2-rollback"
    test "$(hba_errors)" = 0 || die "reload 뒤 pg_hba_file_rules 오류 → a2-rollback"
    test "$(hba_new_rows)" = 1 || die "reload 뒤 $SRC 규칙 수가 1이 아님 → a2-rollback"
    # 매칭 허용 줄은 새로 넣은 1줄뿐이어야 한다.
    BROAD_AFTER=$(hba_broad) || die "reload 뒤 매칭 줄 조회 실패 → a2-rollback"
    test "$(printf '%s\n' "$BROAD_AFTER" | grep -c .)" = 1 && test "$(printf '%s\n' "$BROAD_AFTER" | grep -cF ' 10.20.10.0 255.255.255.0 scram-sha-256')" = 1 \
      || die "reload 뒤 10.20.10.x 매칭 허용 줄이 새 줄 1개가 아님 → a2-rollback"
    # 새 줄을 뺀 나머지 규칙은 순서·내용이 그대로여야 한다(줄 번호는 삽입 뒤 1씩 밀릴 수 있어 비교에서 뺀다).
    diff <(cut -d'|' -f2- "$LOGDIR/hba-rules.before") <(cut -d'|' -f2- "$LOGDIR/hba-rules.after" | grep -vF '|10.20.10.0|255.255.255.0|') \
      || die "기존 pg_hba 규칙 순서·내용이 바뀜 → a2-rollback"
    show
    echo "RESULT a2-apply=OK $(date '+%T') — 파일·reload 신호까지. 실제 판정은 A4(앱 거래 저장·조회)와 음성 시험으로 한다"
    ;;

  a2-rollback)
    sudo -v || die "sudo 인증 실패"
    show
    # 역순. 각 단계는 해당 변경이 있을 때만 되돌리고, 마지막 readback으로 판정한다.
    if sudo -u postgres test -f "$SEC/pg_hba.conf.before"; then
      # 현재 파일이 a2-apply 결과(after)와 같을 때만 사본으로 되돌린다. 그 사이 다른 승인된 pg_hba 변경이
      # 있었으면 덮어쓰지 않고 멈춘다(infra-db#12 하영 리뷰 비차단 1). 이미 before와 같으면 복원은 건너뛴다.
      # 이 단계에서 멈추면 방화벽·경로는 아직 바꾸지 않은 상태다.
      CUR=$(sudo sha256sum "$HBA" | cut -d' ' -f1)
      BEF=$(sudo sha256sum "$SEC/pg_hba.conf.before" | cut -d' ' -f1)
      AFT=$(sudo sha256sum "$SEC/pg_hba.conf.after" 2>/dev/null | cut -d' ' -f1)
      echo "-- pg_hba sha256 현재=$CUR before=$BEF after=${AFT:-없음}"
      if test -n "$CUR" && test "$CUR" = "$BEF"; then
        echo "-- pg_hba가 이미 before와 같음: 복원 건너뜀"
      elif test -n "$CUR" && test -n "$AFT" && test "$CUR" = "$AFT"; then
        sudo -u postgres sh -c 'cat "$1" > "$2"' sh "$SEC/pg_hba.conf.before" "$HBA" || die "pg_hba.conf 복원 실패"
        reload_pg
      else
        die "현재 pg_hba가 a2-apply 결과(after)·이전(before) 어느 쪽과도 다름 — 다른 변경이 있었을 수 있어 덮어쓰지 않는다. 수동 판단(방화벽·경로는 아직 그대로)"
      fi
    else
      echo "-- pg_hba 사본 없음: pg_hba는 바꾸지 않았던 것으로 본다(대상 줄 수 $(sudo grep -cE "$HBA_RE" "$HBA"))"
    fi
    if test "$(fw_state --permanent)" != absent; then
      sudo firewall-cmd --permanent --zone="$ZONE" --remove-rich-rule="$RULE" || true
      sudo firewall-cmd --reload || die "firewalld reload 실패"
    fi
    test "$(fw_state)" = absent || sudo firewall-cmd --zone="$ZONE" --remove-rich-rule="$RULE" || true
    CONN=$(nm_conn) || CONN=""
    # NM 조회 실패(2)를 "없음"으로 보지 않는다. 지울 수 있는 runtime 경로는 계속 정리하고, 판정에서 멈춘다(B4).
    case "$(nm_state "$CONN")" in
      present) sudo nmcli connection modify "$CONN" -ipv4.routes "$TUN $GW" || echo "-- NM 경로 삭제 실패(수동 확인)" ;;
      absent) ;;
      *) echo "-- NM 영구 경로 확인 불가(connection=[$CONN]) — runtime 경로만 정리하고 판정에서 멈춘다" ;;
    esac
    test "$(route_state)" = absent || sudo ip route del "$TUN" via "$GW"
    show
    test "$(hba_new_rows)" = 0 && test "$(hba_errors)" = 0 || die "원복 뒤 pg_hba에 $SRC 규칙이나 오류가 남음"
    test "$(fw_state)" = absent && test "$(fw_state --permanent)" = absent || die "원복 뒤 rich rule이 남음"
    test "$(route_state)" = absent || die "원복 뒤 runtime 경로가 남음"
    test -n "$CONN" || die "NM connection 미확인: 원복 완료 판정 금지"
    case "$(nm_state "$CONN")" in
      absent) ;;
      present) die "원복 뒤 NM 영구 경로가 남음" ;;
      *) die "NM 영구 경로 조회 실패: 원복 완료 판정 금지" ;;
    esac
    test "$(fw_match)" = YES || die "원복 뒤 MATCH가 YES가 아님 — W0 기록과 대조"
    echo "RESULT a2-rollback=OK $(date '+%T')"
    ;;

  *)
    echo "usage: bash $0 check|pre-apply|pre-rollback|a2-apply|a2-rollback <RUN> | render-hba <in> <out>" >&2; exit 2 ;;
esac
