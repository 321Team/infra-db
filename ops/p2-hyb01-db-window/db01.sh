#!/usr/bin/env bash
# #47 DB 변경 창(P1-DB-01 이관) — db01 작업: pg_hba .50 줄 제거, fds_app 비밀번호 검증자 교체.
# 사용: sudo -v 후 `bash db01.sh <mode> <RUN>`   (RUN 예: 20261010T1500, 세 호스트가 같은 값)
#   check        : 변경 없음. pg_hba 유효 줄·pg_hba_file_rules 오류·fds_app 접속 출발지·검증자 지문
#   hba-apply    : pg_hba.conf에서 `hostssl fdsdb fds_app 10.1.93.50/32 scram-sha-256` 1줄만 지우고 reload
#   hba-rollback : hba-apply 직전 사본으로 되돌리고 reload
#   pw-apply     : control01 prepare가 출력한 SCRAM 검증자를 붙여넣어 fds_app 비밀번호 교체
#                  (평문 비밀번호는 db01에 오지 않는다. 이전 검증자는 보관 → pw-rollback)
#   pw-rollback  : 보관한 이전 검증자로 되돌림
#   cleanup      : 창 종료 판정 뒤 이전 검증자 사본 삭제
# 출력은 ~/p2-hyb01-<RUN>/에 남는다(비밀 값 없음). 이전 검증자·pg_hba 사본은 postgres 소유
# /var/lib/pgsql/fds-evidence/p2-hyb01-<RUN>/(700/600)에 둔다.
# set -e는 쓰지 않는다. 단계마다 결과를 보고 멈춘다.
set -uo pipefail

MODE=${1:-}
RUN=${2:-}
case "$RUN" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9]) ;;
  *) echo "usage: bash $0 check|hba-apply|hba-rollback|pw-apply|pw-rollback|cleanup <RUN=yyyymmddTHHMM>" >&2; exit 2 ;;
esac

PGDATA=/var/lib/pgsql/data
HBA=$PGDATA/pg_hba.conf
SEC=/var/lib/pgsql/fds-evidence/p2-hyb01-$RUN
LOGDIR=$HOME/p2-hyb01-$RUN
# 지울 줄. 이 정규식에 정확히 1줄이 맞아야 hba-apply가 진행한다.
LINE_RE='^hostssl[[:space:]]+fdsdb[[:space:]]+fds_app[[:space:]]+10\.1\.93\.50/32[[:space:]]+scram-sha-256[[:space:]]*$'
# PostgreSQL SCRAM 검증자 형식: SCRAM-SHA-256$4096:<salt 16B>$<StoredKey 32B>:<ServerKey 32B>
VER_RE='^SCRAM-SHA-256[$]4096:[A-Za-z0-9+/]{22}==[$][A-Za-z0-9+/]{43}=:[A-Za-z0-9+/]{43}=$'

test "$(hostname -s)" = db01 || { echo "STOP: db01이 아님" >&2; exit 2; }
case "$-" in *x*) echo "STOP: xtrace 상태로 실행 금지" >&2; exit 2 ;; esac

mkdir -p "$LOGDIR" && chmod 700 "$LOGDIR" || { echo "STOP: $LOGDIR 생성 실패" >&2; exit 2; }
LOG=$LOGDIR/db01-$MODE-$(date +%H%M%S).log
exec > >(tee -a "$LOG") 2>&1

die() { echo "STOP: $*"; exit 3; }
pg() { (cd /tmp && sudo -u postgres psql -X -q -A -t -v ON_ERROR_STOP=1 -d fdsdb "$@"); }
# 검증자 지문: 문자열(끝 줄바꿈 제외)의 SHA-256 앞 16자. control01 prepare와 같은 계산.
fp_live() { pg -c "SELECT rolpassword FROM pg_authid WHERE rolname = 'fds_app'" | tr -d '\n' | sha256sum | cut -c1-16; }
fp_str() { printf '%s' "$1" | sha256sum | cut -c1-16; }
hba_errors() { pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL"; }
hba_has50() { pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE address = '10.1.93.50'"; }
reload() { pg -c "SELECT pg_reload_conf()" >/dev/null || die "pg_reload_conf 실패"; sleep 2; }
sec_mkdir() { sudo -u postgres mkdir -p -m 700 "$SEC" || die "$SEC 생성 실패"; }

show() {
  echo "== $(date '+%F %T %Z') db01 mode=$MODE run=$RUN"
  echo "-- pg_hba.conf 유효 줄(줄 번호)"
  sudo grep -nEv '^[[:space:]]*(#|$)' "$HBA"
  echo "-- pg_hba.conf sha256 / mode owner inode size / selinux"
  sudo sha256sum "$HBA"
  sudo stat -c '%a %U:%G inode=%i size=%s' "$HBA"
  sudo stat -c '%C' "$HBA" 2>/dev/null || true
  echo "-- .50 대상 줄 수(파일): $(sudo grep -cE "$LINE_RE" "$HBA")"
  echo "-- pg_hba_file_rules (적용 중 규칙)"
  pg -c "SELECT line_number, type, database, user_name, address, netmask, auth_method, coalesce(error,'') FROM pg_hba_file_rules ORDER BY line_number"
  echo "-- pg_hba_file_rules 오류 수: $(hba_errors)"
  echo "-- fds_app 접속 출발지별 세션 수"
  pg -c "SELECT coalesce(host(client_addr),'local'), count(*) FROM pg_stat_activity WHERE usename = 'fds_app' GROUP BY 1 ORDER BY 1"
  echo "-- password_encryption=$(pg -c 'SHOW password_encryption') log_statement=$(pg -c 'SHOW log_statement')"
  echo "-- fds_app 검증자 지문: $(fp_live)"
}

case "$MODE" in
  check)
    sudo -v || die "sudo 인증 실패"
    show
    ;;

  hba-apply)
    sudo -v || die "sudo 인증 실패"
    show
    test "$(sudo grep -cE "$LINE_RE" "$HBA")" = 1 || die ".50 줄이 정확히 1줄이 아님(이미 지웠거나 형식이 다름)"
    test "$(hba_errors)" = 0 || die "적용 전 pg_hba_file_rules 오류가 있음"
    sec_mkdir
    sudo -u postgres test -e "$SEC/pg_hba.conf.before" && die "이전 사본이 이미 있음($SEC/pg_hba.conf.before). 같은 RUN으로 재적용하지 않는다"
    sudo -u postgres cp -p "$HBA" "$SEC/pg_hba.conf.before" || die "사본 저장 실패"
    sudo -u postgres sh -c 'umask 077; grep -vE "$1" "$2" > "$3"' sh "$LINE_RE" "$HBA" "$SEC/pg_hba.conf.after" || die "새 내용 생성 실패"
    # $SEC는 postgres 700이라 셸 리디렉션(<)으로는 못 읽는다. sudo cat으로 읽는다.
    BEFORE_N=$(sudo cat "$SEC/pg_hba.conf.before" | wc -l)
    AFTER_N=$(sudo cat "$SEC/pg_hba.conf.after" | wc -l)
    echo "-- 줄 수 before=$BEFORE_N after=$AFTER_N, diff:"
    sudo diff "$SEC/pg_hba.conf.before" "$SEC/pg_hba.conf.after"
    test "$AFTER_N" = "$((BEFORE_N - 1))" || die "1줄만 지워지지 않음. 파일은 아직 바꾸지 않았다"
    # cat > 로 덮어써 inode·권한·소유자·SELinux 문맥을 유지한다(sed -i·mv는 새 파일을 만든다).
    sudo -u postgres sh -c 'cat "$1" > "$2"' sh "$SEC/pg_hba.conf.after" "$HBA" || die "pg_hba.conf 쓰기 실패 → hba-rollback"
    reload
    show
    test "$(hba_errors)" = 0 || die "reload 후 pg_hba_file_rules 오류 → hba-rollback"
    test "$(hba_has50)" = 0 || die "reload 후에도 .50 규칙이 남음 → 원인 확인"
    echo "RESULT hba-apply=OK"
    ;;

  hba-rollback)
    sudo -v || die "sudo 인증 실패"
    sudo -u postgres test -f "$SEC/pg_hba.conf.before" || die "사본 없음: $SEC/pg_hba.conf.before"
    show
    sudo -u postgres sh -c 'cat "$1" > "$2"' sh "$SEC/pg_hba.conf.before" "$HBA" || die "pg_hba.conf 복원 실패"
    reload
    show
    test "$(hba_errors)" = 0 || die "복원 후 pg_hba_file_rules 오류"
    test "$(hba_has50)" = 1 || die "복원 후 .50 규칙 수가 1이 아님"
    echo "RESULT hba-rollback=OK"
    ;;

  pw-apply)
    sudo -v || die "sudo 인증 실패"
    show
    sec_mkdir
    OLDV=$SEC/fds_app.verifier.before
    sudo -u postgres test -e "$OLDV" && die "이전 검증자 사본이 이미 있음. 같은 RUN으로 재교체하면 원래 값을 잃는다"
    # 이전 검증자는 파이프로만 옮긴다(화면·argv에 남기지 않음).
    pg -c "SELECT rolpassword FROM pg_authid WHERE rolname = 'fds_app'" | tr -d '\n' \
      | sudo -u postgres sh -c 'umask 077; cat > "$1"' sh "$OLDV" || die "이전 검증자 보관 실패"
    test "$(sudo -u postgres grep -c '^SCRAM-SHA-256[$]4096:' "$OLDV")" = 1 || die "보관한 이전 검증자 형식 이상"
    OLD_FP=$(sudo -u postgres cat "$OLDV" | sha256sum | cut -c1-16)
    echo "-- 이전 검증자 보관: $OLDV (지문 $OLD_FP)"
    read -r -p "control01 prepare가 출력한 검증자 한 줄을 붙여넣고 Enter: " NEWV </dev/tty
    [[ "$NEWV" =~ $VER_RE ]] || { unset NEWV; die "검증자 형식이 아님(줄바꿈·공백 포함 여부 확인). DB는 바꾸지 않았다"; }
    NEW_FP=$(fp_str "$NEWV")
    echo "-- 붙여넣은 검증자 지문: $NEW_FP"
    read -r -p "control01 prepare 출력의 지문과 같으면 YES: " ANS </dev/tty
    test "$ANS" = YES || { unset NEWV; die "지문 확인 안 됨. DB는 바꾸지 않았다"; }
    # printf는 bash 내장이라 검증자가 프로세스 argv에 나타나지 않는다. 기존 세션은 끊기지 않는다.
    printf "ALTER ROLE fds_app PASSWORD '%s';\n" "$NEWV" | pg -f - || { unset NEWV; die "ALTER ROLE 실패"; }
    unset NEWV
    LIVE_FP=$(fp_live)
    echo "-- 적용 후 검증자 지문: $LIVE_FP"
    test "$LIVE_FP" = "$NEW_FP" || die "적용 후 지문 불일치 → pw-rollback"
    echo "RESULT pw-apply=OK $(date '+%T') old_fp=$OLD_FP new_fp=$NEW_FP"
    echo "다음: control01에서 apply(Secret 갱신·rollout). 이 사이 기존 Pod의 새 DB 연결은 인증 실패한다."
    ;;

  pw-rollback)
    sudo -v || die "sudo 인증 실패"
    OLDV=$SEC/fds_app.verifier.before
    sudo -u postgres test -f "$OLDV" || die "이전 검증자 사본 없음: $OLDV"
    echo "-- 되돌리기 전 지문: $(fp_live)"
    OLD_FP=$(sudo -u postgres cat "$OLDV" | sha256sum | cut -c1-16)
    sudo -u postgres cat "$OLDV" | { IFS= read -r V; printf "ALTER ROLE fds_app PASSWORD '%s';\n" "$V"; } | pg -f - || die "ALTER ROLE 실패"
    LIVE_FP=$(fp_live)
    echo "-- 되돌린 후 지문: $LIVE_FP (기대 $OLD_FP)"
    test "$LIVE_FP" = "$OLD_FP" || die "되돌린 후 지문 불일치"
    echo "RESULT pw-rollback=OK $(date '+%T')"
    echo "다음: control01에서 rollback(Secret 원복·rollout)."
    ;;

  cleanup)
    sudo -v || die "sudo 인증 실패"
    if sudo -u postgres test -f "$SEC/fds_app.verifier.before"; then
      sudo -u postgres shred -u "$SEC/fds_app.verifier.before" || die "이전 검증자 삭제 실패"
    fi
    echo "-- 남은 파일(pg_hba 사본은 비밀 없음, 유지)"
    sudo ls -la "$SEC"
    echo "RESULT cleanup=OK"
    ;;

  *)
    echo "usage: bash $0 check|hba-apply|hba-rollback|pw-apply|pw-rollback|cleanup <RUN>" >&2; exit 2 ;;
esac
