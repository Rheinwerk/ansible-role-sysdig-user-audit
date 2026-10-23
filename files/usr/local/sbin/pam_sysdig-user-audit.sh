#!/bin/bash -e

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

# If a session is started and there is no sysdig user audit process running yet, start it.
if [[ "${PAM_TYPE}" == "open_session" && ${sysdigs} -eq 0 ]]; then
	logger -p auth.notice -t pam_exec "No sysdig running on user-login. Starting sysdig-user-audit."
	service sysdig-user-audit start
fi

# If a session is closed and no other session is open, stop the sysdig-user-audit service. If the
# count is unknown, keep it running.
if [[ ${PAM_TYPE} == "close_session" && ${other_sessions} == "0" ]]; then
	logger -t auth.notice -t pam_exec "Closing last user session. Stopping sysdig-user-audit."
	service sysdig-user-audit stop
fi
