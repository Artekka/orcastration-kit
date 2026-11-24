# Security policy

orchestration-kit is shell scripts, Claude Code hooks and skill text that run on your own machine with
your user's rights. A bug in them can run a command you did not mean, leak a path or token into a file,
or change the wrong git worktree. We take reports about that seriously.

## Supported versions

| Version | Security fixes |
|---|---|
| 0.9.x (latest release) | Yes |
| older than 0.9 | No: upgrade to the latest release |

A fix ships as a new patch release and a CHANGELOG entry.

## Reporting a vulnerability

**Do not open a public issue for a vulnerability.** Report it privately through GitHub:

1. Open this repository's **Security** tab
   (https://github.com/Artekka/orcastration-kit/security).
2. Choose **Report a vulnerability**.
3. Say what is affected, how to reproduce it, and what an attacker gains.

Private vulnerability reporting must be switched on by the repository owner. If the button is missing,
open a public issue that asks for a private channel and contains **no** details of the problem.

## What to expect

- An acknowledgment within 7 days.
- A first assessment (accepted, needs more information, or out of scope) within 14 days.
- For an accepted report: a fix or a mitigation in a release, a GitHub security advisory, and credit
  in the advisory if you want it.

This is a small, volunteer-run project; these times are targets, not guarantees. We will tell you if
we expect to miss one.

## Scope

In scope: everything in this repository: the scripts, hooks, skills, templates and the status-HUD plugin.
For example: command injection through a session name, branch name or file path; a hook or script that
writes a secret, token or personal path where others can read it; a guard that can be bypassed into a
destructive git action.

Out of scope: vulnerabilities in Claude Code itself or in Anthropic's services (report those to
Anthropic: https://www.anthropic.com/responsible-disclosure-policy), and in third-party tools the kit
calls (git, tmux, gitleaks).

## Secrets in this repository

CI runs gitleaks on every push and pull request, and `tests/leak-guard.test.sh` fails on personal paths,
email addresses, key shapes and private keys. Contributors can opt in to the same scan before each push;
see [CONTRIBUTING.md](CONTRIBUTING.md#secrets-and-personal-details).
