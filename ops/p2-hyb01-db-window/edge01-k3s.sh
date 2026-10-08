#!/usr/bin/env bash
# #47 DB 변경 창(P1-DB-01 이관) — edge01 옛 E-K3S(k3s) 중지.
# 사용: sudo -v 후 `bash edge01-k3s.sh <mode> <RUN>`
#   check    : 변경 없음. k3s 상태·Pod·NodePort, nginx upstream, 경로 응답, iptables/firewalld 요약
#   stop     : Edge Cutover 완료(nginx가 .50:30080을 더 이상 쓰지 않음)를 확인한 뒤
#              k3s 중지·자동 시작 해제 → k3s-killall.sh로 남은 컨테이너·NodePort 규칙 정리
#   rollback : k3s 자동 시작 복구·기동(데이터 /var/lib/rancher/k3s는 지우지 않으므로 그대로 올라온다)
#   hba-probe <RUN> allowed|rejected
#            : edge01(.50)에서 db01 5432로 SSL 시작 요청 + fds_app/fdsdb StartupMessage만 보내 서버의 첫 응답으로
#              pg_hba 판정을 본다(비밀번호를 보내지 않음, 인증 단계 전에 끊음). 인증 요청(R)=허용, SQLSTATE 28000
#              `no pg_hba.conf entry`=거부, 그 밖(연결 실패·timeout·SSL 거부·다른 오류)=판정 불가.
#              기대와 같으면 rc0, 반대면 rc3, 판정 불가면 rc4. W0에서 allowed, W2 뒤·W3 전에 rejected를 본다.
# `systemctl stop k3s`만으로는 컨테이너(containerd-shim)와 kube-proxy iptables 규칙이 남아
# 옛 백엔드가 계속 db01에 접속할 수 있다. 그래서 k3s-killall.sh까지 실행한다.
# 출력은 ~/p2-hyb01-<RUN>/에 남는다. set -e는 쓰지 않는다.
set -uo pipefail

MODE=${1:-}
RUN=${2:-}
case "$RUN" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9]) ;;
  *) echo "usage: bash $0 check|stop|rollback|hba-probe <RUN=yyyymmddTHHMM> [allowed|rejected]" >&2; exit 2 ;;
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
# ss 자체가 실패하면(옵션·필터 문법·sudo) 0이 아니라 ERR을 내 게이트를 통과하지 못하게 한다.
old_estab() {
  local out
  out=$(sudo ss -Htn state established '( dst 10.1.93.50:30080 or dst 127.0.0.1:30080 or dst [::1]:30080 )') || { echo ERR; return 1; }
  if test -z "$out"; then echo 0; else printf '%s\n' "$out" | wc -l; fi
}
# worker 시작 시각 원천. 시험에서 바꿔 끼울 수 있게 /proc 읽기만 따로 둔다.
proc_stat() { cat "/proc/$1/stat"; }
proc_uptime() { cat /proc/uptime; }
# 디스크 설정이 실행 중 nginx에 반영됐는지: 현재 worker(reload 시 새로 뜸)가 nginx -T가 읽은 설정 파일들의
# 최종 수정 시각 이후에 시작됐는지. 정리 중인 옛 worker("shutting down")는 뺀다. 0=반영(OK), 1=설정이 reload 뒤
# 바뀜(또는 오차 범위 안이라 확정 못 함), 2=판단 불가.
# infra-kubernetes#77(병합 81ad791d)과 같은 방식이다. ps lstart는 쓰지 않는다: 부팅 시각(btime, 초 버림)+경과라
# 최대 1초 이르게 나오고, 이 호스트(ko_KR)에서는 요일·월 이름 때문에 date -d가 해석하지 못해 늘 2가 된다
# (Edge Cutover RUN 20261008T1730에서 같은 판정이 거짓 UNCONFIRMED). 설정은 나노초 mtime, worker는 아래
# worker_start의 보수적 시작 시각 하한과 비교한다.
reloaded_after_conf() {
  local master newest wstart pid t args n_old=0 n_cur=0
  master=$(pgrep -o -x nginx) || return 2
  newest=$(sudo nginx -T 2>/dev/null | sed -n 's/^# configuration file \(.*\):$/\1/p' | while IFS= read -r f; do sudo date -r "$f" +%s.%N; done | sort -n | tail -1)
  wstart=
  for pid in $(pgrep -P "$master" -x nginx); do
    args=$(ps -o args= -p "$pid") || return 2
    case "$args" in *"shutting down"*) n_old=$((n_old + 1)); continue ;; esac
    case "$args" in *"worker process"*) ;; *) continue ;; esac
    t=$(worker_start "$pid") || return 2
    n_cur=$((n_cur + 1))
    if test -z "$wstart" || earlier "$t" "$wstart"; then wstart=$t; fi
  done
  test -n "$newest" && test -n "$wstart" || return 2
  echo "   nginx 설정 최종 수정=$(date -d "@${newest%.*}" '+%F %T').${newest#*.} 현재 worker ${n_cur}개 최초 시작(하한)=$(date -d "@${wstart%.*}" '+%F %T').${wstart#*.} 정리 중 옛 worker=${n_old}"
  earlier "$wstart" "$newest" && return 1
  return 0
}
# $1 < $2 (소수 초)면 0
earlier() { awk -v a="$1" -v b="$2" 'BEGIN { if (a + 0 < b + 0) exit 0; exit 1 }'; }
# worker 시작 시각의 보수적 하한(epoch, 소수 6자리). 실제 시작은 이 값보다 늦다.
# 전제: 측정 동안 벽시계와 부팅 기준 시계의 차이가 일정하다(시계 step이 없음).
#   실제 시작 = 부팅 시각 B + starttime 실제값, starttime 실제값 ≥ s/h (/proc/<pid>/stat 22번째, tick 버림)
#   지금 n을 먼저 읽고 uptime을 나중에 읽으므로, n을 읽은 순간의 실제 uptime U1 ≤ 뒤에 읽은 uptime U2 < u + 0.01
#   (/proc/uptime은 소수 둘째 자리 아래를 버린다) → B = n − U1 > n − u − 0.01
#   → 실제 시작 > n − u + s/h − 0.010. 출력 반올림(%.6f, 0.5µs)까지 덮도록 1ms를 더 빼 0.011을 뺀다.
worker_start() {
  local now up st hz
  hz=$(getconf CLK_TCK) || return 1
  now=$(date +%s.%N) || return 1
  up=$(proc_uptime | awk '{ print $1 }') || return 1
  st=$(proc_stat "$1" | sed 's/^.*) //' | awk '{ print $20 }') || return 1
  awk -v n="$now" -v u="$up" -v s="$st" -v h="$hz" \
    'BEGIN { if (s ~ /^[0-9]+$/ && u ~ /^[0-9.]+$/ && h ~ /^[0-9]+$/ && h > 0) { printf "%.6f\n", n - u + s / h - 0.011; exit 0 } exit 1 }'
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

  hba-probe)
    EXPECT=${3:-}
    case "$EXPECT" in allowed|rejected) ;; *) die "기대값을 allowed 또는 rejected로 준다" ;; esac
    echo "== $(date '+%F %T %Z') edge01 hba-probe run=$RUN expect=$EXPECT → 10.1.93.55:5432 user=fds_app db=fdsdb (비밀번호 없음)"
    python3 - "$EXPECT" <<'PY'
import socket, ssl, struct, sys
expect = sys.argv[1]
host, port = "10.1.93.55", 5432

def out(result, detail):
    print("HBA_PROBE result=%s expect=%s %s" % (result, expect, detail))
    if result == "INCONCLUSIVE":
        sys.exit(4)
    sys.exit(0 if result.lower() == expect else 3)

try:
    sock = socket.create_connection((host, port), timeout=5)
except Exception as e:
    out("INCONCLUSIVE", "tcp=%s:%s" % (type(e).__name__, e))
sock.settimeout(5)
src = sock.getsockname()[0]
try:
    sock.sendall(struct.pack(">ii", 8, 80877103))
    ans = sock.recv(1)
except Exception as e:
    out("INCONCLUSIVE", "src=%s sslrequest=%s:%s" % (src, type(e).__name__, e))
if ans == b"S":
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        sock = ctx.wrap_socket(sock)
    except Exception as e:
        out("INCONCLUSIVE", "src=%s tls=%s:%s" % (src, type(e).__name__, e))
    tls = sock.version()
else:
    out("INCONCLUSIVE", "src=%s sslrequest_answer=%r (hostssl 규칙은 SSL 접속에만 해당)" % (src, ans))
body = struct.pack(">i", 196608)
for k, v in (("user", "fds_app"), ("database", "fdsdb"), ("application_name", "edge01-hba-probe")):
    body += k.encode() + b"\0" + v.encode() + b"\0"
body += b"\0"
try:
    sock.sendall(struct.pack(">i", len(body) + 4) + body)
    head = b""
    while len(head) < 5:
        chunk = sock.recv(5 - len(head))
        if not chunk:
            break
        head += chunk
    if len(head) < 5:
        out("INCONCLUSIVE", "src=%s tls=%s first_message=EOF" % (src, tls))
    mtype = head[:1]
    mlen = struct.unpack(">i", head[1:5])[0]
    payload = b""
    while len(payload) < mlen - 4:
        chunk = sock.recv(mlen - 4 - len(payload))
        if not chunk:
            break
        payload += chunk
finally:
    try:
        sock.close()
    except Exception:
        pass
if mtype == b"R":
    code = struct.unpack(">i", payload[:4])[0] if len(payload) >= 4 else -1
    out("ALLOWED", "src=%s tls=%s first_message=R auth_code=%d (인증 요청 = pg_hba 허용 규칙에 걸림)" % (src, tls, code))
if mtype == b"E":
    fields = {}
    for part in payload.split(b"\0"):
        if part:
            fields[part[:1].decode()] = part[1:].decode("utf-8", "replace")
    state, msg = fields.get("C", ""), fields.get("M", "")
    if state == "28000" and "no pg_hba.conf entry" in msg:
        out("REJECTED", "src=%s tls=%s sqlstate=%s message=%s" % (src, tls, state, msg))
    out("INCONCLUSIVE", "src=%s tls=%s sqlstate=%s message=%s" % (src, tls, state, msg))
out("INCONCLUSIVE", "src=%s tls=%s first_message=%r" % (src, tls, mtype))
PY
    PRC=$?
    echo "RESULT hba-probe=rc$PRC $(date '+%T') (0=기대와 같음, 3=반대, 4=판정 불가)"
    exit "$PRC"
    ;;

  *)
    echo "usage: bash $0 check|stop|rollback|hba-probe <RUN> [allowed|rejected]" >&2; exit 2 ;;
esac
