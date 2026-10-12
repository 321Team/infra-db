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
    --list-rich-rules) cat "$f"; exit 0 ;;
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
  *"route add 10.20.0.0/16 via 10.1.93.51"*) echo "route add" >> "$d/mut"; test -n "${FAKE_ROUTE_ADD_FAIL:-}" && exit 2; test -f "$d/route" && exit 2; touch "$d/route"; exit 0 ;;
  *"route del 10.20.0.0/16 via 10.1.93.51"*) echo "route del" >> "$d/mut"; rm -f "$d/route"; exit 0 ;;
esac
exit 0
X
cat > "$T/bin/nmcli" <<'X'
#!/usr/bin/env bash
d=$FAKE_DIR
case "$*" in
  *"device show ens160"*) echo "ens160"; exit 0 ;;
  *"connection show ens160"*) test -n "${FAKE_NM_FAIL:-}" && { echo "Error: NetworkManager is not running." >&2; exit 8; }; cat "$d/nm" 2>/dev/null; exit 0 ;;
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
# 10.20.10.x 매칭 허용 줄(모의): host* 줄 중 reject가 아니고 주소가 all·samenet·samehost이거나
# 이 대역을 덮는 대표 CIDR(0.0.0.0/0·10.0.0.0/8·10.20.0.0/16)이거나 10.20.10.x 안의 주소.
broad() {
  rules | awk -F'|' '$2 ~ /^host/ && $7 != "reject" &&
    ($5 ~ /^(all|samenet|samehost)$/ || ($5 == "0.0.0.0" && $6 == "0.0.0.0") || ($5 == "10.0.0.0") || ($5 == "10.20.0.0") || $5 ~ /^10\.20\.10\./) {
      print $1 " " $2 " " $3 " " $4 " " $5 " " $6 " " $7 }'
}
# FAKE_PG_FAIL: 모든 질의가 연결 오류로 실패(B2). FAKE_HBA_FILE: 서버 hba_file이 다른 경로.
test -n "${FAKE_PG_FAIL:-}" && { echo 'psql: error: connection to server on socket failed' >&2; exit 2; }
case "$*" in
  *"SHOW hba_file"*) echo "${FAKE_HBA_FILE:-$h}" ;;
  *"auth_method <> 'reject'"*) broad ;;
  *max_connections*) echo "max_connections=100 superuser_reserved=3 sessions=7 authentication_timeout=1min" ;;
  *"address = '10.20.10.0'"*) rules | grep -cF '|10.20.10.0|255.255.255.0|' ;;
  *"error IS NOT NULL"*) echo "${FAKE_HBA_ERRORS:-0}" ;;
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
  test -n "${EXTRA_HBA:-}" && echo "$EXTRA_HBA" >> "$d/root/var/lib/pgsql/data/pg_hba.conf"
  test -n "${KEEP_DIR:-}" && d=$KEEP_DIR
  out=$(FAKE_DIR=$d FAKE_HBA=$d/root/var/lib/pgsql/data/pg_hba.conf DB01_ROSA_TEST_ROOT=$d/root HOME=$d/home     PATH="$T/bin:$PATH" bash "$S" "$2" "${RUNID:-20261021T1000}" 2>&1); rc=$?
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
run "check: 정상 상태면 W0_READY=YES" check 0 'W0_READY(pre-apply)=YES' ""
run "pre-apply: runtime rule + 경로만, receipt 기록" pre-apply 0 'RESULT pre-apply=OK' "add rt,route add"
P=$LAST_DIR; rm -f "$P/mut"
grep -q '^W0 .*rules_sha=' "$P/home/p2-hyb01-rosa-20261021T1000/pre.receipt" && grep -qx 'DONE route' "$P/home/p2-hyb01-rosa-20261021T1000/pre.receipt" \
  && echo "PASS pre-apply: receipt에 W0·INTENT/DONE" || { echo "FAIL pre-apply: receipt"; FAILS=$((FAILS + 1)); }
KEEP_DIR=$P run "pre-apply: 같은 RUN 재적용 거부(receipt 있음)" pre-apply 3 'receipt가 이미 있음' ""
KEEP_DIR=$P run "pre-rollback: 같은 RUN receipt대로 원복, W0 대조" pre-rollback 0 'RESULT pre-rollback=OK .* W0 대조 일치' "remove rt,route del"
rm -f "$P/mut"
KEEP_DIR=$P run "pre-rollback: 원복 뒤 재실행은 건너뛰기만(변경 0)" pre-rollback 0 'RESULT pre-rollback=OK' ""

# B3 — receipt 없는 RUN, 다른 RUN, 이 RUN이 넣지 않은 항목은 지우지 않는다.
EXTRA_RT=$RULE ROUTE=1 run "pre-rollback: receipt 없음 + 같은 rule·경로가 있음 → 지우지 않음" pre-rollback 3 'receipt가 없음' ""
run "pre-apply(다른 RUN 시험 준비)" pre-apply 0 'RESULT pre-apply=OK' "add rt,route add"
Q=$LAST_DIR; rm -f "$Q/mut"
RUNID=20261021T1100 KEEP_DIR=$Q run "pre-rollback: 다른 RUN으로는 지우지 않음" pre-rollback 3 'receipt가 없음' ""
test -f "$Q/route" && grep -qxF "$RULE" "$Q/rt" && echo "PASS pre-rollback 다른 RUN: rule·경로 그대로" || { echo "FAIL pre-rollback 다른 RUN: 지워짐"; FAILS=$((FAILS + 1)); }

# B1 — firewalld reload는 runtime rule만 permanent로 되돌리고 경로는 남긴다. 원복은 둘을 각각 판정한다.
run "pre-apply(reload 시험 준비)" pre-apply 0 'RESULT pre-apply=OK' "add rt,route add"
R1=$LAST_DIR; rm -f "$R1/mut"
cp "$R1/perm" "$R1/rt"   # 창 도중 firewall-cmd --reload
test -f "$R1/route" && echo "PASS reload: 커널 경로는 남음(reload로 정리되지 않음)" || { echo "FAIL reload: 경로 사라짐"; FAILS=$((FAILS + 1)); }
KEEP_DIR=$R1 run "pre-rollback: reload 뒤 — rule은 건너뛰고 경로만 삭제" pre-rollback 0 'RESULT pre-rollback=OK' "route del"
# rule 추가 뒤 경로 추가 실패 → rule만 원복
FAKE_ROUTE_ADD_FAIL=1 run "pre-apply: 경로 추가 실패 → STOP(rule만 추가된 상태)" pre-apply 3 '경로 추가 실패' "add rt,route add"
R2=$LAST_DIR; rm -f "$R2/mut"
KEEP_DIR=$R2 run "pre-rollback: 경로 추가 실패 뒤 rule만 원복" pre-rollback 0 'RESULT pre-rollback=OK' "remove rt"
# 세션 중단: 경로를 넣은 뒤 DONE을 쓰기 전에 끊김 → INTENT로 소유를 판단해 정리
run "pre-apply(중단 시험 준비)" pre-apply 0 'RESULT pre-apply=OK' "add rt,route add"
R3=$LAST_DIR; rm -f "$R3/mut"
sed -i '/^DONE route$/d' "$R3/home/p2-hyb01-rosa-20261021T1000/pre.receipt"
KEEP_DIR=$R3 run "pre-rollback: DONE 없는 INTENT(세션 중단)도 이 RUN 소유로 정리" pre-rollback 0 'RESULT pre-rollback=OK' "remove rt,route del"
# 창 도중 다른 runtime 변경 → 이 RUN 소유분만 정리하고 W0 대조에서 멈춤
run "pre-apply(동시 변경 시험 준비)" pre-apply 0 'RESULT pre-apply=OK' "add rt,route add"
R4=$LAST_DIR; rm -f "$R4/mut"
echo 'rule family="ipv4" source address="10.9.9.9/32" accept' >> "$R4/rt"
KEEP_DIR=$R4 run "pre-rollback: 다른 runtime 변경이 있으면 자기 것만 정리 후 STOP" pre-rollback 3 'STOP' "remove rt,route del"
grep -qF '10.9.9.9/32' "$R4/rt" && echo "PASS pre-rollback 동시 변경: 다른 규칙 보존" || { echo "FAIL pre-rollback 동시 변경: 다른 규칙 삭제"; FAILS=$((FAILS + 1)); }

# B2 — W0 필수 조회가 실패하면 첫 쓰기 전에 멈춘다.
FAKE_PG_FAIL=1 run "pre-apply: psql 조회 실패 → 변경 0" pre-apply 3 'STOP' ""
FAKE_HBA_FILE=/other/pg_hba.conf run "pre-apply: hba_file 불일치 → 변경 0" pre-apply 3 'hba_file' ""
FAKE_HBA_ERRORS=1 run "pre-apply: pg_hba 오류 1(매칭 줄 없음) → 변경 0" pre-apply 3 'pg_hba_file_rules 오류' ""
FAKE_NM_FAIL=1 run "pre-apply: NM 조회 실패 → 변경 0" pre-apply 3 'NM 영구 경로 조회 실패' ""
NMROUTE=1 run "pre-apply: NM 영구 경로가 이미 있음 → 변경 0" pre-apply 3 'NM 영구 경로가 이미 있음' ""
FAKE_PG_FAIL=1 run "check: 조회 실패면 rc0이어도 W0_READY=NO" check 0 'W0_READY(pre-apply)=NO' ""
EXTRA_RT=$RULE run "pre-apply: runtime rule이 이미 있음 → 변경 0" pre-apply 3 'STOP' ""
ROUTE=1 run "pre-apply: 경로가 이미 있음 → 변경 0" pre-apply 3 'STOP' ""
EXTRA_RT='rule family="ipv4" source address="10.9.9.9/32" accept' run "pre-apply: runtime·permanent 불일치 → 변경 0" pre-apply 3 'MATCH가 YES가 아님' ""
EXTRA_PERM=$RULE run "a2-apply: permanent rule이 이미 있음 → 변경 0" a2-apply 3 'STOP' ""
NMROUTE=1 run "a2-apply: NM 영구 경로가 이미 있음 → 변경 0" a2-apply 3 'NM 영구 경로가 이미 있음' ""
# B4 — NM 조회 실패(2)를 "없음"으로 보지 않는다.
FAKE_NM_FAIL=1 run "a2-apply: NM 조회 실패 → 변경 0" a2-apply 3 'NM 영구 경로 조회 실패' ""
# B3(A2) — a2-rollback도 같은 RUN receipt의 INTENT 항목만 되돌린다.
EXTRA_RT=$RULE EXTRA_PERM=$RULE ROUTE=1 NMROUTE=1 run "a2-rollback: receipt 없음 + 같은 rule·경로·NM → 지우지 않음" a2-rollback 3 'receipt가 없음' ""
run "a2-apply(다른 RUN 시험 준비)" a2-apply 0 'RESULT a2-apply=OK' "nm add,route add,add perm,reload"
M=$LAST_DIR; rm -f "$M/mut"
RUNID=20261021T1100 KEEP_DIR=$M run "a2-rollback: 다른 RUN으로는 지우지 않음" a2-rollback 3 'receipt가 없음' ""
FAKE_ROUTE_ADD_FAIL=1 run "a2-apply: runtime 경로 추가 실패 → STOP(NM만 추가된 상태)" a2-apply 3 '경로 추가 실패' "nm add,route add"
PA=$LAST_DIR; rm -f "$PA/mut"
KEEP_DIR=$PA run "a2-rollback: 부분 적용 — 이 RUN이 넣은 NM만 원복" a2-rollback 0 'RESULT a2-rollback=OK' "nm del"
# B4 — a2-apply 뒤 NM 조회 실패: 다른 항목은 정리하되 OK를 내지 않고 NM 경로는 남는다.
run "a2-apply(NM 조회 실패 원복 시험 준비)" a2-apply 0 'RESULT a2-apply=OK' "nm add,route add,add perm,reload"
N=$LAST_DIR; rm -f "$N/mut"
FAKE_NM_FAIL=1 KEEP_DIR=$N run "a2-rollback: NM 조회 실패면 나머지만 정리하고 OK를 내지 않음" a2-rollback 3 '원복 완료 판정 금지' "remove perm,reload,route del"
test -s "$N/nm" && echo "PASS a2-rollback NM 조회 실패: NM 경로는 남아 있고 OK 아님" || { echo "FAIL a2-rollback NM 조회 실패"; FAILS=$((FAILS + 1)); }
# a2-apply 정상 경로 → 같은 상태에서 a2-rollback
run "a2-apply: NM·runtime 경로 → permanent rule·reload → pg_hba 1줄" a2-apply 0 'RESULT a2-apply=OK' "nm add,route add,add perm,reload"
A2=$LAST_DIR
if grep -qxF 'hostssl fdsdb fds_app 10.20.10.0/24 scram-sha-256' "$A2/root/var/lib/pgsql/data/pg_hba.conf"   && test "$(sed -n 4p "$A2/root/var/lib/pgsql/data/pg_hba.conf")" = 'hostssl fdsdb fds_app 10.20.10.0/24 scram-sha-256'; then
  echo "PASS a2-apply: pg_hba 4번째 줄(마지막 fds_app 줄 뒤)"; else echo "FAIL a2-apply: pg_hba 위치"; FAILS=$((FAILS + 1)); fi
rm -f "$A2/mut"
KEEP_DIR=$A2 run "a2-rollback: a2-apply 뒤 전체 원복" a2-rollback 0 'RESULT a2-rollback=OK' "remove perm,reload,nm del,route del"
cmp -s "$T/hba" "$A2/root/var/lib/pgsql/data/pg_hba.conf" && echo "PASS a2-rollback: pg_hba 원본과 같음" || { echo "FAIL a2-rollback: pg_hba 다름"; FAILS=$((FAILS + 1)); }
rm -f "$A2/mut"
KEEP_DIR=$A2 run "a2-apply: 같은 RUN 재적용 거부(receipt 있음)" a2-apply 3 'A2 receipt가 이미 있음' ""
rm -f "$A2/mut"
KEEP_DIR=$A2 run "a2-rollback: 이미 원복된 뒤 재실행은 복원 건너뜀(변경 0)" a2-rollback 0 '이미 before와 같음' ""

# a2-apply 뒤 다른 승인된 pg_hba 변경이 생긴 경우: 덮어쓰지 않고 방화벽·경로도 건드리지 않고 멈춘다(SHA 가드).
run "a2-apply(가드 시험 준비)" a2-apply 0 'RESULT a2-apply=OK' "nm add,route add,add perm,reload"
G=$LAST_DIR; rm -f "$G/mut"
echo 'host all all 10.9.9.9/32 reject' >> "$G/root/var/lib/pgsql/data/pg_hba.conf"
cp "$G/root/var/lib/pgsql/data/pg_hba.conf" "$G/hba.changed"
KEEP_DIR=$G run "a2-rollback: pg_hba가 after와 다르면 덮어쓰지 않고 멈춤(변경 0)" a2-rollback 3 'before) 어느 쪽과도 다름' ""
cmp -s "$G/hba.changed" "$G/root/var/lib/pgsql/data/pg_hba.conf" && echo "PASS a2-rollback 가드: 변경된 pg_hba 보존" || { echo "FAIL a2-rollback 가드: pg_hba가 바뀜"; FAILS=$((FAILS + 1)); }

# 10.20.10.x에 매칭되는 넓은 허용 줄이 이미 있으면 사전 창·A2 모두 변경 0으로 멈춘다(#47 하영 조건 1).
EXTRA_HBA='host all all 0.0.0.0/0 scram-sha-256' run "pre-apply: 0.0.0.0/0 허용 줄 있음 → 변경 0" pre-apply 3 '매칭되는 pg_hba 허용 줄이 이미 있음' ""
EXTRA_HBA='hostssl all all 10.0.0.0/8 scram-sha-256' run "a2-apply: 10.0.0.0/8 허용 줄 있음 → 변경 0" a2-apply 3 '매칭되는 pg_hba 허용 줄이 이미 있음' ""
EXTRA_HBA='hostssl all all samenet scram-sha-256' run "check: samenet 허용 줄을 목록으로 보고(변경 0)" check 0 '허용 줄(넓은 범위 포함, reject 제외): 1' ""
run "check: reject 줄만 있으면 매칭 허용 줄 없음, 연결 여유 기록" check 0 '허용 줄(넓은 범위 포함, reject 제외): 없음' ""
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
