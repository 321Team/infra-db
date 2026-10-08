#!/usr/bin/env bash
# db01 5432/tcp를 pg_hba 승인 출발지로만 허용한다(P1-DB-01, IF-04).
# 사용: sudo -v 후 `bash apply.sh check|apply|rollback`
#   check    : 변경 없이 현재 상태와 적용 예정 내용을 출력(기본)
#   apply    : 승인 출발지 rich rule 3개 추가 → 전체 개방 port 5432/tcp 제거
#   rollback : 추가한 rich rule 제거 → port 5432/tcp 복구(적용 전 상태)
set -euo pipefail

ZONE=public
PORT=5432
# IF-04 승인 출발지: transaction-api Pod egress가 SNAT되는 Worker 3대.
# edge01(.50)은 제외한다(infra-db#6 리뷰, P1-SEC-01 Lead). pg_hba의 .50 줄은 README 후속 항목.
SOURCES=(10.1.93.105 10.1.93.107 10.1.93.108)
MODE=${1:-check}

test "$(hostname -s)" = db01 || { echo "STOP: db01이 아님" >&2; exit 2; }

rule() { printf 'rule family="ipv4" source address="%s/32" port port="%s" protocol="tcp" accept' "$1" "$PORT"; }

show() {
  echo "== $(date '+%F %T %Z') firewalld $ZONE (runtime)"
  sudo firewall-cmd --zone="$ZONE" --list-all
  echo "== permanent"
  sudo firewall-cmd --permanent --zone="$ZONE" --list-all
}

# --reload는 runtime 전용 규칙을 지우므로 runtime과 permanent가 같은지 먼저 본다.
# interfaces 줄은 비교에서 뺀다: NetworkManager가 zone에 붙인 인터페이스(connection.zone)는 runtime에만 보이고
# permanent zone 파일에는 없다(2026-10-08 db01: runtime `ens160 ens192` / permanent 빈 값). 이 바인딩은 --reload 뒤에도
# 유지되지만, 유지되는지는 apply에서 reload 전후 인터페이스 목록으로 다시 확인한다(rt_ifaces).
same_rt_perm() {
  # 첫 줄(zone 이름, runtime에만 "(active)")은 비교에서 뺀다.
  diff <(sudo firewall-cmd --zone="$ZONE" --list-all | tail -n +2 | grep -v '^ *interfaces:') <(sudo firewall-cmd --permanent --zone="$ZONE" --list-all | tail -n +2 | grep -v '^ *interfaces:')
}
rt_ifaces() { sudo firewall-cmd --zone="$ZONE" --list-interfaces | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }
# reload 뒤 runtime 인터페이스 바인딩이 그대로인지. 다르면 원상복구 판단이 필요하므로 멈춘다.
check_ifaces_kept() {
  local after
  after=$(rt_ifaces)
  echo "-- runtime 인터페이스: reload 전 [$IF_BEFORE] / 뒤 [$after]"
  test "$after" = "$IF_BEFORE" || { echo "STOP: reload 뒤 runtime 인터페이스 바인딩이 바뀜 — rollback 판단" >&2; exit 4; }
}

case "$MODE" in
  check)
    show
    if same_rt_perm >/dev/null; then echo "RUNTIME_PERMANENT_MATCH=YES (interfaces 줄 제외)"; else echo "RUNTIME_PERMANENT_MATCH=NO"; same_rt_perm || true; fi
    echo "runtime interfaces=[$(rt_ifaces)] permanent interfaces=[$(sudo firewall-cmd --permanent --zone="$ZONE" --list-interfaces)]"
    echo "== 적용 예정"
    for s in "${SOURCES[@]}"; do echo "+ $(rule "$s")"; done
    echo "- port ${PORT}/tcp"
    ;;
  apply)
    show
    same_rt_perm || { echo "STOP: runtime과 permanent가 다름(--reload 시 runtime 전용 규칙 소실). 원인 확인 후 재실행" >&2; exit 3; }
    IF_BEFORE=$(rt_ifaces)
    # 승인 출발지를 먼저 열고 나서 전체 개방을 닫는다(승인 경로 끊김 방지).
    for s in "${SOURCES[@]}"; do
      sudo firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$(rule "$s")"
    done
    sudo firewall-cmd --permanent --zone="$ZONE" --remove-port="${PORT}/tcp"
    sudo firewall-cmd --reload
    show
    check_ifaces_kept
    ;;
  rollback)
    show
    IF_BEFORE=$(rt_ifaces)
    sudo firewall-cmd --permanent --zone="$ZONE" --add-port="${PORT}/tcp"
    for s in "${SOURCES[@]}"; do
      sudo firewall-cmd --permanent --zone="$ZONE" --remove-rich-rule="$(rule "$s")" || true
    done
    sudo firewall-cmd --reload
    show
    check_ifaces_kept
    ;;
  *)
    echo "usage: $0 check|apply|rollback" >&2; exit 2 ;;
esac
