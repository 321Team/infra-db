#!/usr/bin/env bash
# db01-rosa.sh 모의 시험(STATIC/MOCK). hostname·sudo·firewall-cmd·ip·nmcli·psql을 가짜로 바꿔 실행한다.
# 서버 접속·방화벽·경로·DB 변경 없음. 사용: bash ops/p2-hyb01-rosa-db01/tests/test_db01_rosa.sh
# 판정: 마지막 줄 FAILS=0, 종료 코드 0.
S=$(cd "$(dirname "$0")/.." && pwd)/db01-rosa.sh
T=$(mktemp -d)
mkdir -p "$T/bin"
RULE='rule family="ipv4" source address="10.20.10.0/24" port port="5432" protocol="tcp" accept'
SSH='rule family="ipv4" source address="10.1.93.29/32" service name="ssh" accept'
R105='rule family="ipv4" source address="10.1.93.105/32" port port="5432" protocol="tcp" accept'

printf '#!/usr/bin/env bash\necho "${FAKE_HOST:-db01}"\n' > "$T/bin/hostname"
cat > "$T/bin/sudo" <<'X'
#!/usr/bin/env bash
test "$1" = -v && exit 0
test "$1" = -u && shift 2
exec "$@"
X
cat > "$T/bin/firewall-cmd" <<'X'
#!/usr/bin/env bash
# FAKE_DIR/rt·perm: rich rule 한 줄씩. 변경은 FAKE_DIR/mut에 기록하고 상태 파일에 반영한다.
d=$FAKE_DIR; f=$d/rt
for a in "$@"; do test "$a" = --permanent && f=$d/perm; done
for a in "$@"; do
  case "$a" in
    --query-rich-rule=*) grep -qxF "${a#*=}" "$f" && { echo yes; exit 0; } || { echo no; exit 1; } ;;
    --add-rich-rule=*) echo "add $(basename "$f")" >> "$d/mut"; echo "${a#*=}" >> "$f"; exit 0 ;;
    --remove-rich-rule=*) echo "remove $(basename "$f")" >> "$d/mut"; grep -vxF "${a#*=}" "$f" > "$f.n"; mv "$f.n" "$f"; exit 0 ;;
    --reload) echo reload >> "$d/mut"; cp "$d/perm" "$d/rt"; exit 0 ;;
    --list-interfaces) test "$f" = "$d/perm" && echo "" || echo "ens160 ens192"; exit 0 ;;
    --list-all)
      test "$f" = "$d/perm" && printf 'public (default)\n  interfaces: \n' || printf 'public (default, active)\n  interfaces: ens160 ens192\n'
      printf '  ports: \n  rich rules: \n'; sed 's/^/\t/' "$f"; exit 0 ;;
  esac
done
exit 0
X
cat > "$T/bin/ip" <<'X'
#!/usr/bin/env bash
# FAKE_DIR/route가 있으면 10.20.0.0/16 via 10.1.93.51 경로가 있는 상태
d=$FAKE_DIR; args="$*"
case "$args" in
  *"route show exact 10.20.0.0/16"*) test -f "$d/route" && echo "10.20.0.0/16 via 10.1.93.51 dev ens160"; exit 0 ;;
  *"route get 10.1.93.51"*) echo "10.1.93.51 dev ens160 src 10.1.93.55 uid 1000"; exit 0 ;;
  *"route get 10.20."*) if test -f "$d/route"; then echo "10.20.10.10 via 10.1.93.51 dev ens160 src 10.1.93.55 uid 1000"; else echo "10.20.10.10 via 10.1.93.1 dev ens160 src 10.1.93.55 uid 1000"; fi; exit 0 ;;
  *"route add 10.20.0.0/16 via 10.1.93.51"*) echo "route add" >> "$d/mut"; test -f "$d/route" && exit 2; touch "$d/route"; exit 0 ;;
  *"route del 10.20.0.0/16 via 10.1.93.51"*) echo "route del" >> "$d/mut"; rm -f "$d/route"; exit 0 ;;
esac
exit 0
X
cat > "$T/bin/nmcli" <<'X'
#!/usr/bin/env bash
d=$FAKE_DIR
case "$*" in
  *"device show ens160"*) echo "ens160"; exit 0 ;;
  *"connection show ens160"*) cat "$d/nm" 2>/dev/null; exit 0 ;;
  *"connection modify ens160 +ipv4.routes"*) echo "nm add" >> "$d/mut"; echo "10.20.0.0/16 10.1.93.51" > "$d/nm"; exit 0 ;;
  *"connection modify ens160 -ipv4.routes"*) echo "nm del" >> "$d/mut"; : > "$d/nm"; exit 0 ;;
esac
exit 1
X
cat > "$T/bin/psql" <<'X'
#!/usr/bin/env bash
# pg_hba_file_rules·개수 질의는 FAKE_HBA 파일 내용에서 만든다(실제 뷰도 파일 내용을 읽는다). reload는 t.
h=$FAKE_HBA
rules() {
  test -f "$h" || return 0
  awk '!/^[[:space:]]*(#|$)/ { n++; addr=$4; mask=""; auth=$5
    if ($1=="local") { addr=""; auth=$4 }
    else { split($4,a,"/"); addr=a[1]; m=a[2]+0; mask=(m==32?"255.255.255.255":(m==24?"255.255.255.0":(m==0?"0.0.0.0":"x"))) }
    printf "%d|%s|%s|%s|%s|%s|%s\n", NR, $1, $2, $3, addr, mask, auth }' "$h"
}
case "$*" in
  *"SHOW hba_file"*) echo "$h" ;;
  *"address = '10.20.10.0'"*) rules | grep -cF '|10.20.10.0|255.255.255.0|' ;;
  *count*) echo 0 ;;
  *pg_reload_conf*) echo t ;;
  *pg_hba_file_rules*) rules ;;
esac
exit 0
X
# Windows NTFS(Git Bash)는 mkdir -m 700의 권한 변경을 거부한다. 모드 인자만 빼고 만든다(권한 자체는 이 시험 범위 밖).
cat > "$T/bin/mkdir" <<'X'
#!/usr/bin/env bash
a=(); while test $# -gt 0; do case "$1" in -m) shift 2 ;; -m*) shift ;; *) a+=("$1"); shift ;; esac; done
exec /usr/bin/mkdir "${a[@]}"
X
chmod +x "$T/bin/"*

printf '%s
' 'local all postgres peer' 'hostssl fdsdb fds_app 10.1.93.105/32 scram-sha-256'   'hostssl fdsdb fds_app 10.1.93.107/32 scram-sha-256' 'host all all 0.0.0.0/0 reject' > "$T/hba"
FAILS=0
# 이름 모드 기대rc 기대문구 기대변경목록(공백 구분, -는 무시)
run() {
  local d out rc mut
  d=$(mktemp -d); mkdir -p "$d/home"
  printf '%s\n' "$SSH" "$R105" > "$d/perm"; cp "$d/perm" "$d/rt"
  test -n "${EXTRA_RT:-}" && echo "$EXTRA_RT" >> "$d/rt"
  test -n "${EXTRA_PERM:-}" && echo "$EXTRA_PERM" >> "$d/perm"
  test -n "${ROUTE:-}" && touch "$d/route"
  test -n "${NMROUTE:-}" && echo "10.20.0.0/16 10.1.93.51" > "$d/nm"
  mkdir -p "$d/root/var/lib/pgsql/data" "$d/root/var/lib/pgsql/fds-evidence"
  cp "$T/hba" "$d/root/var/lib/pgsql/data/pg_hba.conf"
  test -n "${KEEP_DIR:-}" && d=$KEEP_DIR
  out=$(FAKE_DIR=$d FAKE_HBA=$d/root/var/lib/pgsql/data/pg_hba.conf DB01_ROSA_TEST_ROOT=$d/root HOME=$d/home     PATH="$T/bin:$PATH" bash "$S" "$2" 20261021T1000 2>&1); rc=$?
  mut=$(test -f "$d/mut" && tr '\n' ',' < "$d/mut" | sed 's/,$//')
  if test "$rc" = "$3" && printf '%s\n' "$out" | grep -q -- "$4" && { test "$5" = - || test "$mut" = "$5"; }; then
    echo "PASS rc=$rc mut=[$mut] $1"
  else
    echo "FAIL rc=$rc(want $3) mut=[$mut](want $5) $1"; printf '%s\n' "$out" | grep -E 'STOP|RESULT|MATCH=' | head -4 | sed 's/^/     /'
    FAILS=$((FAILS + 1))
  fi
  LAST_DIR=$d
}

run "check: 변경 없음" check 0 'rich rule .*runtime=absent permanent=absent' ""
run "pre-apply: runtime rule + 경로만" pre-apply 0 'RESULT pre-apply=OK' "add rt,route add"
EXTRA_RT=$RULE ROUTE=1 run "pre-rollback: pre-apply 상태에서 원복" pre-rollback 0 'RESULT pre-rollback=OK' "remove rt,route del"
run "pre-rollback: 원래 상태에서도 안전(변경 0)" pre-rollback 0 'RESULT pre-rollback=OK' ""
EXTRA_RT=$RULE run "pre-apply: runtime rule이 이미 있음 → 변경 0" pre-apply 3 'STOP' ""
ROUTE=1 run "pre-apply: 경로가 이미 있음 → 변경 0" pre-apply 3 'STOP' ""
EXTRA_RT='rule family="ipv4" source address="10.9.9.9/32" accept' run "pre-apply: runtime·permanent 불일치 → 변경 0" pre-apply 3 'MATCH가 YES가 아님' ""
EXTRA_PERM=$RULE run "a2-apply: permanent rule이 이미 있음 → 변경 0" a2-apply 3 'STOP' ""
NMROUTE=1 run "a2-apply: NM 영구 경로가 이미 있음 → 변경 0" a2-apply 3 'NM 영구 경로가 이미 있음' ""
EXTRA_RT=$RULE EXTRA_PERM=$RULE ROUTE=1 NMROUTE=1 run "a2-rollback: 방화벽·경로 원복(pg_hba 사본 없음)" a2-rollback 0 'RESULT a2-rollback=OK' "remove perm,reload,nm del,route del"
# a2-apply 정상 경로 → 같은 상태에서 a2-rollback
run "a2-apply: NM·runtime 경로 → permanent rule·reload → pg_hba 1줄" a2-apply 0 'RESULT a2-apply=OK' "nm add,route add,add perm,reload"
A2=$LAST_DIR
if grep -qxF 'hostssl fdsdb fds_app 10.20.10.0/24 scram-sha-256' "$A2/root/var/lib/pgsql/data/pg_hba.conf"   && test "$(sed -n 4p "$A2/root/var/lib/pgsql/data/pg_hba.conf")" = 'hostssl fdsdb fds_app 10.20.10.0/24 scram-sha-256'; then
  echo "PASS a2-apply: pg_hba 4번째 줄(마지막 fds_app 줄 뒤)"; else echo "FAIL a2-apply: pg_hba 위치"; FAILS=$((FAILS + 1)); fi
rm -f "$A2/mut"
KEEP_DIR=$A2 run "a2-rollback: a2-apply 뒤 전체 원복" a2-rollback 0 'RESULT a2-rollback=OK' "remove perm,reload,nm del,route del"
cmp -s "$T/hba" "$A2/root/var/lib/pgsql/data/pg_hba.conf" && echo "PASS a2-rollback: pg_hba 원본과 같음" || { echo "FAIL a2-rollback: pg_hba 다름"; FAILS=$((FAILS + 1)); }
rm -f "$A2/mut"
KEEP_DIR=$A2 run "a2-apply: 같은 RUN 재적용 거부(사본 있음)" a2-apply 3 '이전 사본이 이미 있음' ""
rm -f "$A2/mut"
KEEP_DIR=$A2 run "a2-rollback: 이미 원복된 뒤 재실행은 복원 건너뜀(변경 0)" a2-rollback 0 '이미 before와 같음' ""

# a2-apply 뒤 다른 승인된 pg_hba 변경이 생긴 경우: 덮어쓰지 않고 방화벽·경로도 건드리지 않고 멈춘다(SHA 가드).
run "a2-apply(가드 시험 준비)" a2-apply 0 'RESULT a2-apply=OK' "nm add,route add,add perm,reload"
G=$LAST_DIR; rm -f "$G/mut"
echo 'host all all 10.9.9.9/32 reject' >> "$G/root/var/lib/pgsql/data/pg_hba.conf"
cp "$G/root/var/lib/pgsql/data/pg_hba.conf" "$G/hba.changed"
KEEP_DIR=$G run "a2-rollback: pg_hba가 after와 다르면 덮어쓰지 않고 멈춤(변경 0)" a2-rollback 3 'before) 어느 쪽과도 다름' ""
cmp -s "$G/hba.changed" "$G/root/var/lib/pgsql/data/pg_hba.conf" && echo "PASS a2-rollback 가드: 변경된 pg_hba 보존" || { echo "FAIL a2-rollback 가드: pg_hba가 바뀜"; FAILS=$((FAILS + 1)); }

FAKE_HOST=edge01 run "db01이 아니면 멈춤" check 2 'db01이 아님' ""

# render-hba: 마지막 fds_app hostssl 줄 바로 뒤에 1줄
H=$(mktemp -d)
printf '%s\n' 'local all postgres peer' 'hostssl fdsdb fds_app 10.1.93.105/32 scram-sha-256' \
  'hostssl fdsdb fds_app 10.1.93.107/32 scram-sha-256' 'hostssl fdsdb fds_app 10.1.93.108/32 scram-sha-256' \
  'host all all 0.0.0.0/0 reject' > "$H/in"
bash "$S" render-hba "$H/in" "$H/out" >/dev/null; rc=$?
want=$(printf '%s\n' 'local all postgres peer' 'hostssl fdsdb fds_app 10.1.93.105/32 scram-sha-256' \
  'hostssl fdsdb fds_app 10.1.93.107/32 scram-sha-256' 'hostssl fdsdb fds_app 10.1.93.108/32 scram-sha-256' \
  'hostssl fdsdb fds_app 10.20.10.0/24 scram-sha-256' 'host all all 0.0.0.0/0 reject')
if test "$rc" = 0 && test "$(cat "$H/out")" = "$want"; then echo "PASS render-hba: 위치·내용"; else echo "FAIL render-hba: 위치·내용 rc=$rc"; FAILS=$((FAILS + 1)); fi
bash "$S" render-hba "$H/out" "$H/out2" >/dev/null; rc=$?
test "$rc" = 4 && echo "PASS render-hba: 이미 있으면 rc4" || { echo "FAIL render-hba: 이미 있음 rc=$rc"; FAILS=$((FAILS + 1)); }
printf 'local all postgres peer\n' > "$H/none"
bash "$S" render-hba "$H/none" "$H/out3" >/dev/null; rc=$?
test "$rc" = 3 && echo "PASS render-hba: 기준 줄 없으면 rc3" || { echo "FAIL render-hba: 기준 없음 rc=$rc"; FAILS=$((FAILS + 1)); }

echo "FAILS=$FAILS"
test "$FAILS" = 0
