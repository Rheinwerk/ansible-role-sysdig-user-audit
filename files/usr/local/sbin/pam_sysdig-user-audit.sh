#!/bin/bash -e

# Count currently known sessions
w_sessions=$(w --no-header | wc -l)

# Count running sysdig user audit processes
sysdigs=$(ps ax | grep '/usr/bin/sysdig' | grep 'json_useraudit.lua' | grep -v grep | wc -l)

logger -p auth.notice -t pam_exec "w_sessions=${w_sessions}, sysdigs=${sysdigs}, type=${PAM_TYPE}"
logger -p auth.notice -t pam_exec "$(service sysdig-user-audit status)"

if [[ -z "${PAM_TYPE}" ]]; then
	logger -t auth.warn -t pam_exec "Called without PAM_TYPE set. Exiting"
	exit 0
fi

# If a session is started  sessions yet (the one currently logging in is not yet counted),
# and there is no sysdig user audit process running yet, start it.
if [[ "${PAM_TYPE}" == "open_session" && ${sysdigs} -eq 0 ]]; then
	logger -p auth.notice -t pam_exec "No sysdig running on user-login. Starting sysdig-user-audit."
	service sysdig-user-audit start
fi

# If a session is closed, check if it was the last one. If so, stop the sysdig-user-audit
# service.
if [[ ${PAM_TYPE} == "close_session"  && ${w_sessions} -eq 0 ]]; then
	logger -t auth.notice -t pam_exec "Closing last user session. Stopping sysdig-user-audit."
	service sysdig-user-audit stop
fi
