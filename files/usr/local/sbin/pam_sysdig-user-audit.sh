#!/bin/bash -e

# Defaults; the environment can override them (used by the tests, PAM does not set them)
AUDIT_LOG=${AUDIT_LOG:-/var/log/sysdig-user-audit.json}
READY_FLAG=${READY_FLAG:-/run/sysdig-user-audit.ready}
READY_TIMEOUT_MS=${READY_TIMEOUT_MS:-5000}
LOCK=${LOCK:-/run/sysdig-user-audit.lock}

# Wait until the audit records. sysdig needs a moment after its start before it records (~0.2 s with the
# kernel module), and the session's first commands run right after this hook; without the wait they are lost.
# The hook runs below sshd, so the audit records the commands it runs: run a probe command with a unique argument
# until it shows up in the audit log, or until another session has written the ready flag (the unit removes the
# flag when the audit starts or stops). Gives up after READY_TIMEOUT_MS, so a broken audit never blocks logins.
wait_until_recording() {
	local nonce start waited
	[[ -e "${READY_FLAG}" ]] && return 0
	nonce="sysdig-user-audit-ready-$(date +%s%N)-$$"
	start=$(date +%s%N)
	while :; do
		env true "${nonce}"
		waited=$(( ($(date +%s%N) - start) / 1000000 ))
		if [[ -e "${READY_FLAG}" ]] || tail -c 65536 "${AUDIT_LOG}" 2>/dev/null | grep -qF "${nonce}"; then
			touch "${READY_FLAG}"
			logger -p auth.notice -t pam_exec "sysdig-user-audit recording after ${waited} ms"
			return 0
		fi
		if (( waited >= READY_TIMEOUT_MS )); then
			logger -p auth.warning -t pam_exec "sysdig-user-audit not recording after ${waited} ms"
			return 0
		fi
		sleep 0.05
	done
}

# Print the number of open login sessions other than the one this hook runs for, as logind sees them.
# w(1) cannot be used: Debian 13 has no utmp, so w lists logind sessions there, including non-TTY sessions
# and the session that is being closed. pam_systemd sets XDG_SESSION_ID and pam_exec passes it on.
# Sessions of class "manager" (systemd >= 256, one per user manager) and sessions already closing do not count.
# Returns non-zero if loginctl fails.
count_other_sessions() {
	local sessions id class state count=0
	sessions=$(loginctl list-sessions --no-legend) || return 1
	for id in $(awk '{print $1}' <<< "${sessions}"); do
		[[ "${id}" == "${XDG_SESSION_ID:-}" ]] && continue
		class=$(loginctl show-session "${id}" -p Class --value) || return 1
		state=$(loginctl show-session "${id}" -p State --value) || return 1
		[[ "${class}" == user* && "${state}" != "closing" ]] && count=$((count + 1))
	done
	echo "${count}"
}

# Serialize the decisions of concurrent PAM sessions: a logout counts the other sessions and stops the audit, a
# login starts it. Without the lock, a login can register between the last logout's count and its stop and then
# run unrecorded. The lock is released before the readiness wait, which can take a while.
exec 9> "${LOCK}"
if ! flock -w 10 9; then
	logger -p auth.warning -t pam_exec "sysdig-user-audit: no lock after 10 s, continuing without it"
fi

# Count the other open login sessions; "unknown" if logind cannot be asked
if ! other_sessions=$(count_other_sessions); then
	other_sessions=unknown
fi

# Count running sysdig user audit processes
sysdigs=$(ps ax | grep '/usr/bin/sysdig' | grep 'json_useraudit.lua' | grep -v grep | wc -l)

logger -p auth.notice -t pam_exec "other_sessions=${other_sessions}, sysdigs=${sysdigs}, type=${PAM_TYPE}"
logger -p auth.notice -t pam_exec "$(service sysdig-user-audit status)"

if [[ -z "${PAM_TYPE}" ]]; then
	logger -t auth.warn -t pam_exec "Called without PAM_TYPE set. Exiting"
	exit 0
fi

# If a session is started, make sure the audit runs and records before the session's commands do. The start is
# also issued when a sysdig process exists: it may be the one of an audit that is just stopping, and starting a
# running unit does nothing.
if [[ "${PAM_TYPE}" == "open_session" ]]; then
	if [[ ${sysdigs} -eq 0 ]]; then
		logger -p auth.notice -t pam_exec "No sysdig running on user-login. Starting sysdig-user-audit."
	fi
	service sysdig-user-audit start
	flock -u 9
	wait_until_recording
fi

# If a session is closed and no other session is open, stop the sysdig-user-audit service. If the
# count is unknown, keep it running.
if [[ ${PAM_TYPE} == "close_session" && ${other_sessions} == "0" ]]; then
	logger -t auth.notice -t pam_exec "Closing last user session. Stopping sysdig-user-audit."
	service sysdig-user-audit stop
fi
flock -u 9
