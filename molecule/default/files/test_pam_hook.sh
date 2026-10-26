#!/bin/bash
# Tests pam_sysdig-user-audit.sh (session counting, readiness wait) with stubbed loginctl, service, logger, ps, w
# and env.
# Usage: test_pam_hook.sh <path to pam_sysdig-user-audit.sh>
# Prints "ok <case>" or "FAIL <case>: <reason>" per case and exits non-zero if any case failed.
set -u

HOOK=$1
FAILED=0
CASE_DIRS=()
trap 'rm -rf "${CASE_DIRS[@]}"' EXIT
SYSDIG_PS='12345 ?        Sl     0:01 /usr/bin/sysdig -c /usr/local/share/sysdig/chisels/json_useraudit.lua'

# make_stubs <dir>: stub commands that read the case's fixtures from $FIX and record calls in $CALLS / $LOGS
make_stubs() {
	local bin=$1
	mkdir -p "$bin"
	cat > "$bin/loginctl" <<'EOF'
#!/bin/bash
[[ -e "$FIX/fail" ]] && exit 1
case "$1" in
	list-sessions) echo "loginctl list-sessions" >> "$CALLS"; cat "$FIX/list" 2>/dev/null ;;
	show-session) id=$2; prop=$4; cat "$FIX/$id.$prop" ;;
	*) exit 2 ;;
esac
EOF
	cat > "$bin/service" <<'EOF'
#!/bin/bash
echo "$*" >> "$CALLS"
EOF
	cat > "$bin/logger" <<'EOF'
#!/bin/bash
echo "$*" >> "$LOGS"
EOF
	cat > "$bin/ps" <<'EOF'
#!/bin/bash
cat "$FIX/ps" 2>/dev/null
EOF
	cat > "$bin/w" <<'EOF'
#!/bin/bash
echo "w-called" >> "$CALLS"
EOF
	# env stands in for the readiness probe "env true <nonce>": counts its calls; on call $FIX/record_on it
	# "records" the probe (appends the nonce to the audit log), on call $FIX/flag_on it writes the ready flag
	cat > "$bin/env" <<'EOF'
#!/bin/bash
n=$(( $(cat "$FIX/env_calls" 2>/dev/null || echo 0) + 1 )); echo $n > "$FIX/env_calls"
echo "probe" >> "$CALLS"
[[ -e "$FIX/record_on" && $n -eq $(cat "$FIX/record_on") ]] && echo "{\"evt_args\":\"$2\"}" >> "$AUDIT_LOG"
[[ -e "$FIX/flag_on" && $n -eq $(cat "$FIX/flag_on") ]] && touch "$READY_FLAG"
exit 0
EOF
	cat > "$bin/flock" <<'EOF'
#!/bin/bash
echo "flock $*" >> "$CALLS"
EOF
	chmod 0755 "$bin"/*
}

# session <id> <class> <state>: fixture answers for loginctl show-session
session() {
	echo "$2" > "$FIX/$1.Class"
	echo "$3" > "$FIX/$1.State"
}

# run_case <name> <PAM_TYPE> <XDG_SESSION_ID or "-" for unset> <check function>
# The case's fixtures are written by the caller into $FIX before run_case is called.
run_case() {
	local name=$1 pam_type=$2 session_id=$3 check=$4 rc
	CALLS=$CASE_DIR/calls LOGS=$CASE_DIR/logs
	: > "$CALLS"; : > "$LOGS"; touch "$CASE_DIR/audit.json"
	local timeout; timeout=$(cat "$FIX/timeout" 2>/dev/null || echo 1000)
	local vars=(PATH="$CASE_DIR/bin:$PATH" FIX="$FIX" CALLS="$CALLS" LOGS="$LOGS" PAM_TYPE="$pam_type"
		AUDIT_LOG="$CASE_DIR/audit.json" READY_FLAG="$CASE_DIR/ready" READY_TIMEOUT_MS="$timeout" LOCK="$CASE_DIR/lock")
	local t0; t0=$(date +%s%N)
	if [[ "$session_id" == "-" ]]; then
		/usr/bin/env -u XDG_SESSION_ID "${vars[@]}" bash -e "$HOOK" > "$CASE_DIR/out" 2>&1
	else
		/usr/bin/env "${vars[@]}" XDG_SESSION_ID="$session_id" bash -e "$HOOK" > "$CASE_DIR/out" 2>&1
	fi
	rc=$?
	ELAPSED_MS=$(( ($(date +%s%N) - t0) / 1000000 ))
	local reason=""
	grep -q 'w-called' "$CALLS" && reason="w was called"
	grep -q 'other_sessions=' "$LOGS" || reason="${reason:+$reason; }no other_sessions= in the log"
	[[ $rc -eq 0 ]] || reason="${reason:+$reason; }exit status $rc"
	local own; own=$($check) || reason="${reason:+$reason; }$own"
	if [[ -z "$reason" ]]; then
		echo "ok $name"
	else
		echo "FAIL $name: $reason (calls: $(tr '\n' '|' < "$CALLS"))"
		FAILED=1
	fi
}

stopped() { grep -qx 'sysdig-user-audit stop' "$CALLS" || { echo "expected a stop"; return 1; }; }
not_stopped() { ! grep -q 'stop' "$CALLS" || { echo "unexpected stop"; return 1; }; }
started() { grep -qx 'sysdig-user-audit start' "$CALLS" || { echo "expected a start"; return 1; }; }
not_started() { ! grep -q 'start' "$CALLS" || { echo "unexpected start"; return 1; }; }
# in_order <pattern>...: each pattern's first line in $CALLS comes after the previous one's
in_order() {
	local prev=0 n pat
	for pat in "$@"; do
		n=$(grep -n -m1 -E "$pat" "$CALLS" | cut -d: -f1)
		[[ -n "$n" && $n -gt $prev ]] || { echo "order: '$pat' missing or before line $prev"; return 1; }
		prev=$n
	done
}
locked_count_and_stop() { stopped > /dev/null && in_order '^flock -w' '^loginctl list-sessions' 'sysdig-user-audit stop' '^flock -u' || { in_order '^flock -w' '^loginctl list-sessions' 'sysdig-user-audit stop' '^flock -u'; return 1; }; }
locked_start_then_wait() { recorded > /dev/null && in_order '^flock -w' 'sysdig-user-audit start' '^flock -u' '^probe' || { in_order '^flock -w' 'sysdig-user-audit start' '^flock -u' '^probe'; return 1; }; }
# readiness wait
recorded() {
	started > /dev/null && [[ -e "$CASE_DIR/ready" ]] && grep -q 'recording after' "$LOGS" \
		|| { echo "expected start, flag and 'recording after'"; return 1; }
}
no_probe() { started > /dev/null && [[ ! -e "$FIX/env_calls" ]] || { echo "expected start without probe"; return 1; }; }
timed_out() {
	started > /dev/null && [[ ! -e "$CASE_DIR/ready" ]] && grep -q 'not recording after' "$LOGS" && (( ELAPSED_MS < 2000 )) \
		|| { echo "expected a warning, no flag, < 2 s (took ${ELAPSED_MS} ms)"; return 1; }
}
flag_by_other() {
	started > /dev/null && ! grep -q 'not recording after' "$LOGS" && [[ -e "$CASE_DIR/ready" ]] \
		|| { echo "expected to stop waiting once the flag appeared"; return 1; }
}

# new_case: fresh fixture and stub directories. Under /var/tmp, because the molecule containers mount /tmp
# noexec and the stubs must be executable.
new_case() {
	CASE_DIR=$(mktemp -d -p "${TEST_TMPDIR:-/var/tmp}")
	CASE_DIRS+=("$CASE_DIR")
	FIX=$CASE_DIR/fix
	mkdir -p "$FIX"
	make_stubs "$CASE_DIR/bin"
}

# systemd 257 (Debian 13): SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE
new_case
printf '%s\n' '128 1000 cd-admin - 338006 user    - no -' '129 1000 cd-admin - 338011 manager - no -' > "$FIX/list"
session 128 user active; session 129 manager active
run_case own_and_manager_only close_session 128 stopped

new_case
printf '%s\n' '128 1000 cd-admin - 338006 user - no -' '129 1000 cd-admin - 338011 manager - no -' \
	'130 1000 cd-admin - 338100 user - no -' > "$FIX/list"
session 128 user active; session 129 manager active; session 130 user active
run_case other_user_active close_session 128 not_stopped

new_case
printf '%s\n' '128 1000 cd-admin - 338006 user - no -' '130 1000 cd-admin - 338100 user - no -' > "$FIX/list"
session 128 user active; session 130 user closing
run_case closing_other_counts_zero close_session 128 stopped

# systemd 252 (Debian 12): SESSION UID USER SEAT TTY
new_case
printf '%s\n' '    339 1000 cd-admin          ' '     c3 1000 cd-admin     pts/0' > "$FIX/list"
session 339 user active; session c3 user active
run_case debian12_format close_session 339 not_stopped

new_case
: > "$FIX/list"
run_case no_session_id_counts_others close_session - stopped

new_case
touch "$FIX/fail"
run_case loginctl_failure_keeps_running close_session 128 not_stopped

# the lock serializes count+stop and start, so a login cannot slip between the last logout's count and its stop
new_case
printf '%s\n' '128 1000 cd-admin - 338006 user - no -' > "$FIX/list"
session 128 user active
run_case close_counts_and_stops_under_the_lock close_session 128 locked_count_and_stop

new_case
: > "$FIX/list"; echo '1 ? Ss 0:01 /sbin/init' > "$FIX/ps"; echo 2 > "$FIX/record_on"
run_case open_starts_under_the_lock_and_waits_outside open_session 128 locked_start_then_wait

# open_session: start (idempotent), then wait until the audit records a probe command or the ready flag exists
new_case
: > "$FIX/list"; echo '1 ? Ss 0:01 /sbin/init' > "$FIX/ps"; echo 3 > "$FIX/record_on"
run_case open_waits_until_recorded open_session 128 recorded

new_case
: > "$FIX/list"; echo "$SYSDIG_PS" > "$FIX/ps"; touch "$CASE_DIR/ready"
run_case open_no_wait_when_flag_exists open_session 128 no_probe

new_case
: > "$FIX/list"; echo '1 ? Ss 0:01 /sbin/init' > "$FIX/ps"; echo 300 > "$FIX/timeout"
run_case open_times_out open_session 128 timed_out

new_case
: > "$FIX/list"; echo "$SYSDIG_PS" > "$FIX/ps"; echo 2 > "$FIX/flag_on"
run_case open_stops_waiting_when_flag_appears open_session 128 flag_by_other

new_case
: > "$FIX/list"; echo "$SYSDIG_PS" > "$FIX/ps"; echo 1 > "$FIX/record_on"
run_case open_starts_even_when_running open_session 128 recorded

exit $FAILED
