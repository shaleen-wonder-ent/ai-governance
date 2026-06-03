# Security Policy

## Repository protection model
This repository contains Azure Policy definitions, initiatives, and assignment
scripts that govern AI model usage. Unauthorized changes to these files can
silently weaken security controls in production subscriptions.

To prevent that, the following controls are enforced:

- The `main` branch is protected:
  - All changes must go through a Pull Request.
  - At least **1 approving review** from a CODEOWNER (the repo owner) is required.
  - Stale approvals are dismissed when new commits are pushed.
  - Force pushes and branch deletion are blocked.
  - Conversation resolution is required.
  - Admin bypass is disabled.
- `.github/CODEOWNERS` routes review of every file to the repo owner.
- Workflows from first-time contributors require maintainer approval before they run.

## Reporting a vulnerability
If you discover a security issue (a policy gap, a script that leaks credentials,
or a way to bypass approval), **do not** open a public issue.

Instead, contact the repository owner privately via GitHub:
- GitHub: @shaleen-wonder-ent

Please include:
- A clear description of the issue
- Steps to reproduce
- Affected files / commits
- Suggested remediation (if any)

You will receive an acknowledgement within a reasonable timeframe.

## Handling suspected unauthorized activity
If you suspect the repository or an account with access has been compromised:
1. Rotate any PATs / SSH keys that had push access.
2. Review `Settings ▸ Security ▸ Audit log` (or the personal account security log) for unexpected events.
3. Review `Settings ▸ Collaborators` and `Settings ▸ Deploy keys` and remove anything unrecognized.
4. Review recent commits, branches, releases, and workflow runs.
5. Re-run `scripts/protect-repo.ps1` to re-assert branch protection settings.
