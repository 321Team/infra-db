#!/usr/bin/env bash
# apply.sh runtime·permanent 비교 모의 시험(STATIC/MOCK). sudo·hostname·firewall-cmd를 가짜로 바꿔 실행한다.
# 서버 접속·방화벽 변경 없음. 사용: bash ops/db01-firewall-5432/tests/test_apply_match.sh
# 판정: 마지막 줄 FAILS=0, 종료 코드 0.
S=$(cd "$(dirname "$0")/.." && pwd)/apply.sh
T=$(mktemp -d)
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho db01\n' > "$T/bin/hostname"
printf '#!/usr/bin/env bash\n"$@"\n' > "$T/bin/sudo"
cat > "$T/bin/firewall-cmd" <<'X'
#!/usr/bin/env bash
# FAKE_DIR/rt·perm 파일 내용을 --list-all로 돌려준다. 변경 명령은 FAKE_DIR/mut에 기록만 한다.
d=$FAKE_DIR; perm=0
for a in "$@"; do test "$a" = --permanent && perm=1; done
case "$*" in
  *--reload*) echo reload >> "$d/mut"; exit 0 ;;
  *--add-rich-rule*|*--remove-port*|*--add-port*|*--remove-rich-rule*) echo "$*" >> "$d/mut"; exit 0 ;;
  *--list-interfaces*) test "$perm" = 1 && echo "" || echo "ens160 ens192"; exit 0 ;;
  *--list-all*)
    test -n "$FAIL" && test "$perm" = 1 && { n=$(( $(cat "$d/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/n"; test "$n" -gt 1 && { echo error >&2; exit 1; }; }
    test "$perm" = 1 && cat "$d/perm" || cat "$d/rt"; exit 0 ;;
esac
exit 0
X
chmod +x "$T/bin/"*

# zone 출력: $1=첫 줄, $2=interfaces, $3=ports, 나머지=rich rule 줄
zone() {
  printf '%s\n  target: default\n  icmp-block-inversion: no\n  interfaces: %s\n  sources: \n  services: \n  ports: %s\n  forward: yes\n  rich rules: \n' "$1" "$2" "$3"
  shift 3
  for r in "$@"; do printf '\t%s\n' "$r"; done
}
R105='rule family="ipv4" source address="10.1.93.105/32" port port="5432" protocol="tcp" accept'
R107='rule family="ipv4" source address="10.1.93.107/32" port port="5432" protocol="tcp" accept'
R108='rule family="ipv4" source address="10.1.93.108/32" port port="5432" protocol="tcp" accept'
SSH='rule family="ipv4" source address="10.1.93.29/32" service name="ssh" accept'

FAILS=0
run() { # 이름 모드 기대rc 기대문구 기대변경수(-는 무시)
  local d out rc mut
  d=$(mktemp -d); cp "$T/rt" "$d/rt"; cp "$T/perm" "$d/perm"
  out=$(FAKE_DIR=$d FAIL=${FAIL:-} PATH="$T/bin:$PATH" bash "$S" "$2" 2>&1); rc=$?
  mut=0; test -f "$d/mut" && mut=$(wc -l < "$d/mut")
  if test "$rc" = "$3" && printf '%s\n' "$out" | grep -q -- "$4" && { test "$5" = - || test "$mut" = "$5"; }; then
    echo "PASS rc=$rc mutations=$mut $1"
  else
    echo "FAIL rc=$rc(want $3) mutations=$mut(want $5) $1"; printf '%s\n' "$out" | grep -E 'MATCH|STOP' | head -3 | sed 's/^/     /'
    FAILS=$((FAILS + 1))
  fi
}

# 1) 실측(W5) 모양: 같은 규칙, 순서만 다름 → YES
zone 'public (default, active)' 'ens160 ens192' '' "$R108" "$SSH" "$R107" "$R105" > "$T/rt"
zone 'public (default)' '' '' "$R105" "$R107" "$R108" "$SSH" > "$T/perm"
run "check: rich rule 순서만 다름 → YES" check 0 'MATCH=YES' -

# 2) 규칙 하나가 runtime에만 있음 → NO, apply는 변경 0건으로 rc3
zone 'public (default, active)' 'ens160 ens192' '5432/tcp' "$SSH" "$R105" > "$T/rt"
zone 'public (default)' '' '5432/tcp' "$SSH" > "$T/perm"
run "check: runtime 전용 rich rule → NO" check 0 'MATCH=NO' -
run "apply: runtime 전용 rich rule → 중단" apply 3 'STOP: runtime·permanent' 0

# 3) rich rule은 같고 ports 줄이 다름 → NO
zone 'public (default, active)' 'ens160 ens192' '5432/tcp' "$SSH" > "$T/rt"
zone 'public (default)' '' '' "$SSH" > "$T/perm"
run "check: ports 줄 다름 → NO" check 0 'MATCH=NO' -

# 4) 같은 개수지만 내용이 다른 규칙(정렬해도 다름) → NO
zone 'public (default, active)' 'ens160 ens192' '' "$R105" "$R107" > "$T/rt"
zone 'public (default)' '' '' "$R107" "$R108" > "$T/perm"
run "check: 다른 규칙 → NO" check 0 'MATCH=NO' -

# 5) 변경 전 실측 모양(interfaces만 다름) → apply 진행, 변경 5건(rich 3·port 1·reload 1)
zone 'public (default, active)' 'ens160 ens192' '5432/tcp' "$SSH" > "$T/rt"
zone 'public (default)' '' '5432/tcp' "$SSH" > "$T/perm"
run "apply: interfaces만 다름 → 적용" apply 0 'runtime 인터페이스' 5

# 6) permanent 조회 실패 → QUERY_ERROR / apply 변경 0건
FAIL=1 run "check: permanent 조회 실패 → QUERY_ERROR" check 0 'QUERY_ERROR' -
FAIL=1 run "apply: permanent 조회 실패 → 중단" apply 3 'STOP' 0

echo "FAILS=$FAILS"
test "$FAILS" = 0
