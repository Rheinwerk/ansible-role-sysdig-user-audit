sysdig-user-audit installation
=========

This role can be used to install a sysdig based user activity audit service

[![Build Status](https://github.com/Rheinwerk/ansible-role-sysdig-user-audit/actions/workflows/ci.yml/badge.svg)](https://github.com/Rheinwerk/ansible-role-sysdig-user-audit/actions/workflows/ci.yml)

Requirements
------------

Assumes sysdig to be installed.

Role Variables
--------------

None.

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

