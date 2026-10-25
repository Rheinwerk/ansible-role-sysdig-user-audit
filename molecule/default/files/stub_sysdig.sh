#!/bin/bash
# Stands in for sysdig in the molecule containers: keeps running, so the unit stays active and the PAM hook
# sees a process with /usr/bin/sysdig and the chisel path in its command line.
# Writes the readiness flag like the PAM hook does once a real audit records its probe.
touch /run/sysdig-user-audit.ready
while :; do sleep 1; done
