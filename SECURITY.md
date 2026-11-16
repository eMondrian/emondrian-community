# Security Policy

## Supported versions

Security fixes are made in the
[latest eMondrian Community release](https://github.com/eMondrian/emondrian-community/releases/latest).
Please check that a problem still occurs there before reporting it.

## Reporting a vulnerability

Please do not report a vulnerability in a public issue. Report it privately by email to
contact@bisolutions.dev.

Please include:

- the eMondrian Community release, and the server image and module versions
  (`docker compose images`, the jar names in `modules/`);
- whether authentication was on (`./auth/scripts/authentication.sh status`);
- the part affected: server, authentication gateway, MCP, Dashboard, OLAP Client or entry page;
- the steps to reproduce it and what it lets an attacker do;
- whether any of it is already public.

We acknowledge a report within 3 business days.

After setup, authentication is off and anyone who can reach the server has all rights, as
the README describes under **Authentication**; that is the documented behaviour, not a
vulnerability.
