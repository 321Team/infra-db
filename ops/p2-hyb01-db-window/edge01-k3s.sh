#!/usr/bin/env bash
# #47 DB 변경 창(P1-DB-01 이관) — edge01 옛 E-K3S(k3s) 중지.
# 사용: sudo -v 후 `bash edge01-k3s.sh <mode> <RUN>`
#   check    : 변경 없음. k3s 상태·Pod·NodePort, nginx upstream, 경로 응답, iptables/firewalld 요약
#   stop     : Edge Cutover 완료(nginx가 .50:30080을 더 이상 쓰지 않음)를 확인한 뒤
#              k3s 중지·자동 시작 해제 → k3s-killall.sh로 남은 컨테이너·NodePort 규칙 정리
#   rollback : k3s 자동 시작 복구·기동(데이터 /var/lib/rancher/k3s는 지우지 않으므로 그대로 올라온다)
# `systemctl stop k3s`만으로는 컨테이너(containerd-shim)와 kube-proxy iptables 규칙이 남아
# 옛 백엔드가 계속 db01에 접속할 수 있다. 그래서 k3s-killall.sh까지 실행한다.
# 출력은 ~/p2-hyb01-<RUN>/에 남는다. set -e는 쓰지 않는다.
set -uo pipefail

MODE=${1:-}
RUN=${2:-}
case "$RUN" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9]) ;;
  *) echo "usage: bash $0 check|stop|rollback <RUN=yyyymmddTHHMM>" >&2; exit 2 ;;
esac

K3S=/usr/local/bin/k3s
KILLALL=/usr/local/bin/k3s-killall.sh
# 옛 upstream(E-K3S NodePort)과 정본 upstream(Worker NodePort)
OLD_RE='(10\.1\.93\.50|127\.0\.0\.1|localhost):30080'
NEW_WORKERS=(10.1.93.105 10.1.93.107 10.1.93.108)
LOGDIR=$HOME/p2-hyb01-$RUN

test "$(hostname -s)" = edge01 || { echo "STOP: edge01이 아님" >&2; exit 2; }
mkdir -p "$LOGDIR" && chmod 700 "$LOGDIR" || { echo "STOP: $LOGDIR 생성 실패" >&2; exit 2; }
LOG=$LOGDIR/edge01-$MODE-$(date +%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

die() { echo "STOP: $*"; exit 3; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1"; }
# nginx -T에서 주석(# 이후)을 지운 유효 설정. 주석 처리된 upstream 줄은 세지 않는다.
nginx_eff() { sudo nginx -T 2>/dev/null | sed -e 's/#.*$//'; }
old_refs() { nginx_eff | grep -cE "(^|[^0-9.])$OLD_RE"; }
new_refs() {
  local n=0 w
  for w in "${NEW_WORKERS[@]}"; do
    nginx_eff | grep -qE "(^|[^0-9.])${w//./[.]}:30080" && n=$((n + 1))
  done
  echo "$n"
}
# 실행 중 nginx가 옛 E-K3S NodePort에 붙어 있는 연결 수(디스크 설정이 아니라 실제 소켓)
old_estab() { sudo ss -Htn state established '( dst 10.1.93.50:30080 or dst 127.0.0.1:30080 or dst [::1]:30080 )' | wc -l; }
# 디스크 설정이 실행 중 nginx에 반영됐는지: worker 시작 시각(reload 시 새로 뜸)이 nginx -T가 읽은
# 설정 파일들의 최종 수정 시각 이후인지. 0=반영(OK), 1=설정이 reload 뒤 바뀜, 2=판단 불가
reloaded_after_conf() {
  local master newest wstart pid t
  master=$(pgrep -o -x nginx) || return 2
  newest=$(sudo nginx -T 2>/dev/null | sed -n 's/^# configuration file \(.*\):$/\1/p' | while IFS= read -r f; do sudo stat -c %Y "$f"; done | sort -n | tail -1)
  wstart=
  for pid in $(pgrep -P "$master" -x nginx); do
    t=$(date -d "$(ps -o lstart= -p "$pid")" +%s) || return 2
    if test -z "$wstart" || test "$t" -lt "$wstart"; then wstart=$t; fi
  done
  test -n "$newest" && test -n "$wstart" || return 2
  echo "   nginx 설정 최종 수정=$(date -d "@$newest" '+%F %T') worker 최초 시작=$(date -d "@$wstart" '+%F %T')"
  test "$wstart" -ge "$newest" || return 1
  return 0
}
shim_count() { pgrep -fc 'containerd-shim' || true; }

show() {
  echo "== $(date '+%F %T %Z') edge01 mode=$MODE run=$RUN"
  echo "-- k3s active=$(systemctl is-active k3s) enabled=$(systemctl is-enabled k3s 2>/dev/null) shim=$(shim_count)"
  ls -l "$K3S" "$KILLALL" 2>&1
  if test "$(systemctl is-active k3s)" = active; then
    echo "-- E-K3S 노드·Pod·Service"
    sudo "$K3S" kubectl get nodes -o wide
    sudo "$K3S" kubectl get pods -A -o wide
    sudo "$K3S" kubectl get svc -A
  fi
  echo "-- nginx 설정 검사: $(sudo nginx -t 2>&1 | tail -1)"
  echo "-- nginx upstream/proxy_pass 줄"
  sudo nginx -T 2>/dev/null | grep -nE 'upstream|server[[:space:]]+[0-9.]+:[0-9]+|proxy_pass' || true
  echo "-- 유효 설정(주석 제외) 옛 upstream 참조 수(${OLD_RE})=$(old_refs), 정본 Worker 참조 수=$(new_refs)/3"
  echo "-- 옛 E-K3S NodePort(.50/127.0.0.1:30080) ESTABLISHED 연결 수=$(old_estab)"
  reloaded_after_conf; echo "-- 설정 reload 반영 판정 rc=$? (0=반영, 1=reload 뒤 설정 변경, 2=판단 불가)"
  echo "-- 응답: nginx .50:80/readyz=$(code http://10.1.93.50/readyz) E-K3S .50:30080/readyz=$(code http://10.1.93.50:30080/readyz)"
  for w in "${NEW_WORKERS[@]}"; do echo "   Worker $w:30080/readyz=$(code "http://$w:30080/readyz")"; done
  echo "-- 수신 포트(30080·6443·10250)"
  sudo ss -ltnp | grep -E ':(30080|6443|10250)[[:space:]]' || echo "   (없음)"
  echo "-- iptables 줄 수: k8s 관련=$(sudo iptables-save | grep -cE 'KUBE-|CNI-|flannel') 그 밖=$(sudo iptables-save | grep -vcE 'KUBE-|CNI-|flannel')"
  echo "-- firewalld state=$(sudo firewall-cmd --state 2>&1)"
  sudo firewall-cmd --list-all 2>/dev/null || true
}

case "$MODE" in
  check)
    sudo -v || die "sudo 인증 실패"
    show
    ;;

  stop)
    sudo -v || die "sudo 인증 실패"
    show
    test "$(sudo nginx -t 2>&1 | grep -c 'test is successful')" = 1 || die "nginx -t 실패"
    test "$(old_refs)" = 0 || die "nginx가 아직 옛 E-K3S upstream을 참조함(Edge Cutover 전). k3s를 멈추지 않는다"
    test "$(new_refs)" = 3 || die "nginx 유효 설정(주석 제외)에서 정본 Worker 3대 upstream을 모두 찾지 못함"
    reloaded_after_conf || die "실행 중 nginx가 현재 설정으로 reload됐는지 확인되지 않음(위 시각 참고). Edge Cutover 담당 확인 전 k3s를 멈추지 않는다"
    # 경로 응답을 몇 번 만든 뒤 옛 NodePort로 붙은 연결이 없는지 본다.
    for i in 1 2 3 4 5; do code http://10.1.93.50/readyz >/dev/null; done
    test "$(old_estab)" = 0 || die "옛 E-K3S NodePort로 ESTABLISHED 연결이 있음(실행 중 nginx 또는 다른 클라이언트가 아직 사용). k3s를 멈추지 않는다"
    test "$(code http://10.1.93.50/readyz)" = 200 || die "nginx 경유 /readyz가 200이 아님. k3s를 멈추지 않는다"
    test -x "$KILLALL" || die "$KILLALL 없음"
    sudo systemctl stop k3s || die "systemctl stop k3s 실패"
    sudo systemctl disable k3s || die "systemctl disable k3s 실패"
    sudo "$KILLALL" || die "k3s-killall.sh 실패 → 상태 확인 후 rollback 판단"
    sleep 3
    show
    test "$(systemctl is-active k3s)" = active && die "k3s가 아직 active"
    test "$(shim_count)" = 0 || die "containerd-shim이 남아 있음"
    test "$(code http://10.1.93.50:30080/readyz)" = 000 || die "E-K3S .50:30080이 아직 응답함"
    test "$(code http://10.1.93.50/readyz)" = 200 || die "nginx 경유 /readyz가 200이 아님 → rollback 판단"
    echo "RESULT k3s-stop=OK $(date '+%T')"
    ;;

  rollback)
    sudo -v || die "sudo 인증 실패"
    show
    sudo systemctl enable --now k3s || die "systemctl enable --now k3s 실패"
    i=0
    while test "$i" -lt 24; do
      sudo "$K3S" kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
      sleep 5; i=$((i + 1))
    done
    show
    echo "RESULT k3s-rollback=$(systemctl is-active k3s) $(date '+%T') (Pod 기동은 위 목록으로 판단)"
    ;;

  *)
    echo "usage: bash $0 check|stop|rollback <RUN>" >&2; exit 2 ;;
esac
