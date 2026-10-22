# orchestrate: deploys and the log

Read by the seat before it claims the DEPLOY or LOG slot (SKILL.md §7). Section numbers match SKILL.md.

## 7 · Wave-train deploys

- **Couple rows into one train when the INTERMEDIATE state is worse than either endpoint** (LESSON 55), not merely because they are related.
- Deploy after each reconcile wave (1–3 rows finishing together); a hotfix or human-awaited fix ships immediately. Main never sits ahead of live past a working day.
- Claim DEPLOY slot (written + pushed BEFORE running) → announce the window → run **ORCHESTRATION.md → Deploy `vehicle`** → verify with its `post-deploy` check (a marker from this train in the live artifact + the version string) → release the slot with the verified version.
- Siblings never deploy while the banner stands; they hand SHAs to the seat.
- **Deploy policy** = ORCHESTRATION.md → Deploy `deploy_policy:`. `ask` (default): ask the human before running the vehicle. `auto-when-green`: a train whose rows all passed READ and whose gate is green deploys without asking; tell the human after, with the verified version. Never ask under `auto-when-green`, never skip the ask under `ask`.

## 8 · Log

Claim LOG slot (number allocated inside the claim text) → append the entry to the log (ORCHESTRATION.md → Docs; default `docs/timeline/build-log.md`) **with Edit — old_string = its last lines, new_string = those + the entry; NEVER Write** — and refresh the status doc (version, test count, deferred) in the SAME pass. A dispatched doc agent gets that Edit rule verbatim → **verify the diff: append-only (`git diff <log> | grep -c '^-[^-]'` = 0) and every fact checked** (LESSON 23) → commit yourself → release the slot.

