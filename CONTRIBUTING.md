# Contributing to orchestration-kit

Thanks for helping. Bug reports, fixes, docs and new lessons from your own multi-session setups are all
welcome. By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

**Found a security problem?** Do not open an issue; follow [SECURITY.md](SECURITY.md).

## Setup

You need a Unix shell with `bash`, `git`, `awk`, `python3`, `pgrep`, `flock` and `timeout` (any recent
Linux or WSL has them). The tests are developed on Linux and WSL; on macOS some cases skip.

```bash
git clone https://github.com/Artekka/orcastration-kit.git
cd orcastration-kit
bash tests/run.sh
```

`tests/run.sh` runs every `tests/*.test.sh` and ends with `ALL TESTS PASSED` or `SOME TESTS FAILED`.
The tests use no network and never start a real Claude session (every `claude` is a stand-in process).
The status HUD's TypeScript suite runs only when the `claude` CLI is on your PATH
(`claude plugin test plugins/status-hud`); otherwise `run.sh` prints a `SKIP` line for it.

To try your change in a real project, install the plugin from your local clone:

```bash
claude plugin marketplace add /path/to/your/clone
claude plugin install orchestration-kit@artekka-kits --scope project
```

## Branches and pull requests

1. Fork the repository and create a branch from `main` with a short name, such as `fix/recycle-timeout`.
2. Keep one topic per pull request. A small PR is reviewed faster.
3. Add or update a test in `tests/` for every behavior change. A fix comes with a test that fails
   without it.
4. Run `bash tests/run.sh` and make sure it passes.
5. Open the pull request against `main` and fill in the template. CI runs the tests and a secret scan;
   both must be green before a merge.
6. A maintainer reviews and merges. Releases (version bump, CHANGELOG entry) are cut by the maintainer,
   so you do not need to edit the version.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `type: summary`, such as

```
fix: recycle waits for the old session to exit before it relaunches
feat: gate-throttle --log writes the slot history
docs: explain the session cap in GETTING-STARTED
test: cover start-team with the seat already running
```

Common types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `ci`. Explain **why** in the body
when the change is not obvious.

No sign-off is needed: this project does not use a DCO or a CLA. Your contribution is licensed under the
repository's [MIT License](LICENSE).

## Style

- US English in every file (color, behavior, canceled, organize).
- Shell scripts: `bash`, `set -u` at least, quote every expansion, and no machine-specific paths.
- Skills and templates are terse: steps, commands and tables, with a one-line reason at most.

## Secrets and personal details

Never commit a token, a key, a personal email address or a path from your own machine. Use
placeholders such as `/home/u`, `/home/user` or `you@example.com`, and a GitHub noreply address
(`ID+name@users.noreply.github.com`) as your git email if you do not want your own address in the
history.

Two checks enforce this:

- `tests/leak-guard.test.sh` (part of `tests/run.sh`) fails on a `/home/<user>` or `/Users/<user>`
  path, an email address that is not a noreply or `example.com` form, AWS, GitHub, Anthropic and OpenAI
  key shapes, and private-key headers, in every tracked or new file.
- CI runs [gitleaks](https://github.com/gitleaks/gitleaks) with `.gitleaks.toml` on the commits of every
  push and pull request.

**Optional: scan before you push.** The repository ships a pre-push hook that runs gitleaks on the
commits you push and then the leak guard. Nothing installs it for you; to opt in, install
[gitleaks](https://github.com/gitleaks/gitleaks#installing) and run:

```bash
bash .github/hooks/install-pre-push.sh              # install (refuses to replace a different hook)
bash .github/hooks/install-pre-push.sh --force      # replace your existing pre-push hook (kept as .bak)
bash .github/hooks/install-pre-push.sh --uninstall  # remove it
```

If the hook stops a push for a false positive, check the finding, then push with `git push --no-verify`
and say so in the pull request.
