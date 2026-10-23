#!/bin/bash
# Tests the session counting of pam_sysdig-user-audit.sh with stubbed loginctl, service, logger, ps and w.
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
	list-sessions) cat "$FIX/list" 2>/dev/null ;;
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
	: > "$CALLS"; : > "$LOGS"
	if [[ "$session_id" == "-" ]]; then
		env -u XDG_SESSION_ID PATH="$CASE_DIR/bin:$PATH" FIX="$FIX" CALLS="$CALLS" LOGS="$LOGS" \
			PAM_TYPE="$pam_type" bash -e "$HOOK" > "$CASE_DIR/out" 2>&1
	else
		env PATH="$CASE_DIR/bin:$PATH" FIX="$FIX" CALLS="$CALLS" LOGS="$LOGS" \
			PAM_TYPE="$pam_type" XDG_SESSION_ID="$session_id" bash -e "$HOOK" > "$CASE_DIR/out" 2>&1
	fi
	rc=$?
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

new_case
: > "$FIX/list"; echo '1 ? Ss 0:01 /sbin/init' > "$FIX/ps"
run_case open_starts_when_absent open_session 128 started

new_case
: > "$FIX/list"; echo "$SYSDIG_PS" > "$FIX/ps"
run_case open_no_start_when_running open_session 128 not_started

exit $FAILED
