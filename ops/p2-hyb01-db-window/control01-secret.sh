#!/usr/bin/env bash
# #47 DB 변경 창(P1-DB-01 이관) — control01: fds_app 새 비밀번호 생성, SCRAM 검증자 출력,
# transaction-api-db-credentials/DATABASE_URL 갱신과 transaction-api rollout.
# 사용: `sudo bash control01-secret.sh <mode> <RUN>`
#   check    : 변경 없음. Secret metadata(값 없음)·현재 값 지문·sanitized URL, Deployment 전략, Pod·EndpointSlice
#   prepare  : 현재 DATABASE_URL 보관 → 새 비밀번호 생성 → 새 DATABASE_URL·SCRAM 검증자를 파일(600)로 만든다.
#              검증자는 터미널에만 출력한다(로그 제외). db01 `pw-apply`에 붙여넣는다.
#   apply    : (db01 pw-apply 뒤) Secret을 새 DATABASE_URL로 patch → 지문 대조 → rollout restart·status
#   rollback : (db01 pw-rollback 뒤) Secret을 보관한 이전 DATABASE_URL로 patch → rollout restart·status
#   cleanup  : 창 종료 판정 뒤 비밀 파일 삭제(shred)
# 평문 비밀번호는 control01 root 전용 디렉터리 파일과 K8s Secret에만 있다. db01에는 검증자만 간다.
# `kubectl apply`는 last-applied-configuration 주석에 Secret 값을 복사하므로 쓰지 않는다.
# infra-kubernetes scripts/create-secrets-safe.sh db-url이 apply를 쓰므로 이번 창에서는 이 스크립트의 patch를 쓴다.
# set -e는 쓰지 않는다.
set -uo pipefail

MODE=${1:-}
RUN=${2:-}
case "$RUN" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9]) ;;
  *) echo "usage: sudo bash $0 check|prepare|apply|rollback|cleanup <RUN=yyyymmddTHHMM>" >&2; exit 2 ;;
esac

test "$(id -u)" = 0 || { echo "STOP: sudo bash로 실행" >&2; exit 2; }
test "$(hostname -s)" = k8s-control01 || { echo "STOP: k8s-control01이 아님" >&2; exit 2; }
case "$-" in *x*) echo "STOP: xtrace 상태로 실행 금지" >&2; exit 2 ;; esac

K=(kubectl --kubeconfig=/etc/kubernetes/admin.conf)
NS=fds-app
SECRET=transaction-api-db-credentials
KEY=DATABASE_URL
DEP=transaction-api
BASE=/root/p2-hyb01-$RUN
S=$BASE/secret
umask 077
mkdir -p "$S" && chmod 700 "$BASE" "$S" || { echo "STOP: $S 생성 실패" >&2; exit 2; }
LOG=$BASE/control01-$MODE-$(date +%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

die() { echo "STOP: $*"; exit 3; }
live_value() { "${K[@]}" -n "$NS" get secret "$SECRET" -o jsonpath="{.data.$KEY}" | base64 -d; }
fp_live() { live_value | sha256sum | cut -c1-16; }
fp_file() { sha256sum < "$1" | cut -c1-16; }
# 값을 출력하지 않고 scheme://user:***@host/db?query 형태로만 보인다.
sanitize() {
  python3 -I -c '
import sys, re
s = sys.stdin.read()
m = re.match(r"^([a-z0-9+]+://)([^:@/]+):[^@]*(@.*)$", s)
print(m.group(1) + m.group(2) + ":***" + m.group(3) if m else "(형식 불일치)")
'
}

show() {
  echo "== $(date '+%F %T %Z') control01 mode=$MODE run=$RUN"
  echo "-- Secret metadata(값 없음)"
  "${K[@]}" -n "$NS" get secret "$SECRET" -o go-template='created={{.metadata.creationTimestamp}} rv={{.metadata.resourceVersion}} type={{.type}}
data_keys={{range $k, $v := .data}}{{$k}} {{end}}
label_keys={{range $k, $v := .metadata.labels}}{{$k}} {{end}}
annotation_keys={{range $k, $v := .metadata.annotations}}{{$k}} {{end}}
{{range .metadata.managedFields}}managed: {{.manager}} {{.operation}} {{.time}}
{{end}}'
  echo "-- 현재 값 지문=$(fp_live) URL=$(live_value | sanitize)"
  echo "-- Deployment $DEP"
  "${K[@]}" -n "$NS" get deploy "$DEP" -o jsonpath='replicas={.spec.replicas} ready={.status.readyReplicas} updated={.status.updatedReplicas} strategy={.spec.strategy}{"\n"}restartedAt={.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}{"\n"}'
  "${K[@]}" -n "$NS" get pods -o wide
  "${K[@]}" -n "$NS" get endpointslice -l kubernetes.io/service-name=transaction-api-nodeport -o wide
}

# Secret의 DATABASE_URL 한 키만 파일 내용으로 바꾼다. 값은 argv에 두지 않고 patch 파일(600)로 넘긴다.
patch_from() {
  local src=$1 pf=$S/patch.json
  python3 -I - "$src" "$pf" "$KEY" <<'PY' || return 1
import base64, json, sys
src, out, key = sys.argv[1:4]
data = open(src, 'rb').read()
if not data or b'\n' in data:
    sys.exit('값 파일이 비었거나 줄바꿈 포함')
with open(out, 'w') as f:
    json.dump({'data': {key: base64.b64encode(data).decode()}}, f)
PY
  "${K[@]}" -n "$NS" patch secret "$SECRET" --type merge --patch-file "$pf"
  local rc=$?
  shred -u "$pf"
  return $rc
}

rollout() {
  "${K[@]}" -n "$NS" rollout restart deploy/"$DEP" || return 1
  "${K[@]}" -n "$NS" rollout status deploy/"$DEP" --timeout=300s
}

case "$MODE" in
  check)
    show
    python3 --version
    ;;

  prepare)
    show
    test -e "$S/new-url" && die "이미 prepare됨($S/new-url). 다시 하려면 db01 적용 전인지 확인 후 cleanup"
    live_value > "$S/old-url" || die "현재 값 읽기 실패"
    test -s "$S/old-url" || die "현재 값이 비어 있음"
    python3 -I - "$S" <<'PY' || die "새 값 생성 실패(DB·Secret은 바꾸지 않았다)"
import base64, hashlib, hmac, os, re, secrets, sys

d = sys.argv[1]

def b64(b):
    return base64.b64encode(b).decode()

def keys(password, salt, it):
    salted = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, it)
    client_key = hmac.new(salted, b'Client Key', hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b'Server Key', hashlib.sha256).digest()
    return client_key, stored_key, server_key

# 자체 검사: RFC 7677 §3 SCRAM-SHA-256 예시(user/pencil)의 ClientProof·ServerSignature 재현
salt = base64.b64decode('W22ZaJ0SNY7soEsUEjb6gQ==')
ck, sk, svk = keys('pencil', salt, 4096)
auth = ('n=user,r=rOprNGfwEbeRWgbNEkqO,'
        'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,'
        'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0').encode()
csig = hmac.new(sk, auth, hashlib.sha256).digest()
proof = bytes(a ^ b for a, b in zip(ck, csig))
ssig = hmac.new(svk, auth, hashlib.sha256).digest()
if (b64(proof), b64(ssig)) == ('dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=',
                               '6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4='):
    print('-- SCRAM 자체 검사(RFC 7677 예시) OK')
else:
    sys.exit('SCRAM 자체 검사 실패')

old = open(os.path.join(d, 'old-url')).read()
m = re.match(r'^(postgresql\+asyncpg://)(fds_app):[^@]*(@10\.1\.93\.55:5432/fdsdb(\?.*)?)$', old)
if not m:
    sys.exit('현재 DATABASE_URL 형식이 예상(postgresql+asyncpg://fds_app:***@10.1.93.55:5432/fdsdb)과 다름')
# 비밀번호 외 부분(쿼리 포함)은 바꾸지 않는다. 2026-10-07 live 값은 SSL 파라미터가 없다
# (asyncpg 기본 prefer로 SSL 협상, db01 원격 허용은 hostssl뿐이라 평문 연결은 거부됨).
# 다만 disable/allow처럼 SSL을 끄는 값이 있으면 멈춘다.
if re.search(r'[?&](ssl|sslmode)=(disable|allow)(&|$)', old):
    sys.exit('현재 DATABASE_URL이 SSL을 끄는 값(disable/allow)을 가짐 — 확인 필요')
if not re.search(r'[?&](ssl|sslmode)=', old):
    print('-- 참고: SSL 파라미터 없음(asyncpg 기본 prefer). 쿼리는 그대로 유지')

# URL에 그대로 넣을 수 있는 문자만(token_urlsafe: A-Z a-z 0-9 - _), 32자
pw = secrets.token_urlsafe(24)
new = m.group(1) + m.group(2) + ':' + pw + m.group(3)
salt = os.urandom(16)
_, sk, svk = keys(pw, salt, 4096)
ver = 'SCRAM-SHA-256$4096:%s$%s:%s' % (b64(salt), b64(sk), b64(svk))
del pw
for name, val in (('new-url', new), ('verifier', ver)):
    fd = os.open(os.path.join(d, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, val.encode())
    os.close(fd)
PY
    echo "-- 새 URL=$(sanitize < "$S/new-url") 지문=$(fp_file "$S/new-url")"
    echo "-- 검증자 지문=$(fp_file "$S/verifier")"
    # 검증자는 로그(tee)에 남기지 않고 터미널에만 보낸다.
    { echo; echo "===== db01 pw-apply에 붙여넣을 검증자(한 줄) ====="; cat "$S/verifier"; echo; echo "====="; } > /dev/tty
    echo "RESULT prepare=OK $(date '+%T') 다음: db01 pw-apply → 이 호스트 apply"
    ;;

  apply)
    for f in old-url new-url verifier; do test -s "$S/$f" || die "$S/$f 없음(prepare 먼저)"; done
    show
    read -r -p "db01 pw-apply가 RESULT pw-apply=OK이고 new_fp가 $(fp_file "$S/verifier")이면 YES: " ANS </dev/tty
    test "$ANS" = YES || die "확인 안 됨. Secret은 바꾸지 않았다"
    patch_from "$S/new-url" || die "Secret patch 실패 → db01 pw-rollback 판단"
    test "$(fp_live)" = "$(fp_file "$S/new-url")" || die "patch 후 Secret 지문 불일치 → rollback"
    echo "-- Secret 지문 일치 $(fp_live) $(date '+%T')"
    rollout; RC=$?
    show
    test "$RC" = 0 || die "rollout status 실패/시간초과(rc=$RC). 기존 Pod 유지 여부를 위 목록으로 확인 → 원인 확인 또는 db01 pw-rollback 후 rollback"
    echo "RESULT apply=OK $(date '+%T')"
    ;;

  rollback)
    test -s "$S/old-url" || die "$S/old-url 없음"
    show
    patch_from "$S/old-url" || die "Secret patch 실패"
    test "$(fp_live)" = "$(fp_file "$S/old-url")" || die "patch 후 Secret 지문 불일치"
    echo "-- Secret 이전 값 복원, 지문 $(fp_live) $(date '+%T')"
    rollout; RC=$?
    show
    test "$RC" = 0 || die "rollout status 실패/시간초과(rc=$RC)"
    echo "RESULT rollback=OK $(date '+%T')"
    ;;

  cleanup)
    for f in old-url new-url verifier patch.json; do
      test -e "$S/$f" && shred -u "$S/$f"
    done
    rmdir "$S" || die "$S가 비지 않음"
    ls -la "$BASE"
    echo "RESULT cleanup=OK"
    ;;

  *)
    echo "usage: sudo bash $0 check|prepare|apply|rollback|cleanup <RUN>" >&2; exit 2 ;;
esac
