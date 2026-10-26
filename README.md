sysdig-user-audit installation
=========

This role can be used to install a sysdig based user activity audit service

[![Build Status](https://github.com/Rheinwerk/ansible-role-sysdig-user-audit/actions/workflows/ci.yml/badge.svg)](https://github.com/Rheinwerk/ansible-role-sysdig-user-audit/actions/workflows/ci.yml)

Requirements
------------

Assumes sysdig to be installed.

The PAM hook counts sessions with systemd-logind, so `/etc/pam.d/sshd` must run `pam_systemd` (on Debian `@include common-session` does once `libpam-systemd` is installed). Without it, SSH sessions are not registered with logind and the first logout stops the audit even when other sessions are still open.

How it works
------------

The role installs `sysdig-user-audit.service` (not enabled) and the `pam_exec` hook `/usr/local/sbin/pam_sysdig-user-audit.sh` in `/etc/pam.d/sshd`. The audit runs while somebody is logged in via SSH:

- Login: the hook starts the service and waits until the audit records, so the first commands of the session are not lost. It runs a probe command `env true sysdig-user-audit-ready-<nonce>` every 50 ms until the probe shows up in `/var/log/sysdig-user-audit.json`, then writes `/run/sysdig-user-audit.ready`. Later logins find the flag and do not wait; the service removes it when it starts or stops. With the kernel module the wait takes about 0.2 to 0.4 s. After 5 s the hook gives up and logs `sysdig-user-audit not recording after ... ms`, so a broken audit delays logins but never blocks them. The probe lines stay in the audit log.
- Logout: the hook counts the other open login sessions with `loginctl` (class `user*`, not `closing`; the session being closed and `manager` sessions do not count) and stops the service when none is left. If `loginctl` fails, the audit keeps running.
- Counting and stopping on logout, and starting on login, run under a lock (`/run/sysdig-user-audit.lock`), so a login cannot slip in between the last logout's count and its stop.
- Every SSH session counts, including sessions without a TTY (`ssh host command`, scp, sftp). The former count with `w` only saw TTY sessions.

The hook logs its decisions to syslog with the tag `pam_exec`.

Role Variables
--------------

| Variable | Default | Description |
| --- | --- | --- |
| `_sysdig_user_audit.detect_ssh_port_forwarding` | `false` | When `true`, extends the `json_useraudit.lua` chisel filter to also capture `connect()`/`accept()` syscalls performed by the `sshd` process itself (not just its child processes), in order to detect SSH port forwarding (`-L`/`-R`/`-D`). Adds an `evt_fwd_direction` field (`"outbound (-L/-D)"` or `"inbound (-R)"`) to matching events. Defaults to `false` so existing consumers of this role are unaffected. |
| `_sysdig_user_audit.driver` | `kmod` | How sysdig captures events. `kmod` uses sysdig's kernel module (built by DKMS from the sysdig `.deb`); `modern_bpf` starts sysdig with `--modern-bpf`, its CO-RE eBPF probe, which needs no kernel module, DKMS or kernel headers but a kernel >= 5.8 with BTF (`/sys/kernel/btf/vmlinux`). The events and the log format are the same. A dict without this key uses `kmod`. |

Dependencies
------------

None.


Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - hosts: servers
      roles:
         - { role: sysdig-user-audit, tags: [ 'sysdig-user-audit' ] }

License
-------

Please see LICENSE.

Author Information
------------------

Original author is [Daniel Schneller](https://github.com/dschneller) as member of the [Rheinwerk](https://github.com/Rheinwerk) project.

