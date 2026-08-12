sysdig-user-audit installation
=========

This role can be used to install a sysdig based user activity audit service

[![Build Status](https://github.com/Rheinwerk/ansible-role-sysdig-user-audit/actions/workflows/ci.yml/badge.svg)](https://github.com/Rheinwerk/ansible-role-sysdig-user-audit/actions/workflows/ci.yml)

Requirements
------------

Assumes sysdig to be installed.

Role Variables
--------------

| Variable | Default | Description |
| --- | --- | --- |
| `_sysdig_user_audit.detect_ssh_port_forwarding` | `false` | When `true`, extends the `json_useraudit.lua` chisel filter to also capture `connect()`/`accept()` syscalls performed by the `sshd` process itself (not just its child processes), in order to detect SSH port forwarding (`-L`/`-R`/`-D`). Adds an `evt_fwd_direction` field (`"outbound (-L/-D)"` or `"inbound (-R)"`) to matching events. Defaults to `false` so existing consumers of this role are unaffected. |

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

