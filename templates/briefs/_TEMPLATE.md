# <ROW> — <one-line title>

> Copy to `docs/orchestration/briefs/<ROW>.md`, fill every section, commit + push BEFORE the assign
> message. The builder runs `/orchestration-kit:orient-brief <ROW>`, which injects ONLY this file + the
> board banner. Contract only: no reasoning, no history of how you got here.

| field | value |
|---|---|
| row | `<ROW>` (the seat's prefix) · severity · tracker/issue id or `—` |
| seat | `<Name> [<ref>]` (era-<N>): the READY goes here, and the builder's READY names it |
| model / effort | `opus[1m]` · `sonnet[1m]` · `haiku` (orchestrate skill, "Model per lane") · `--effort <level>` or default |
| base branch | `origin/main` or `origin/<train-branch>` @ `<sha>` |
| branch / worktree | `<prefix>/<row-lowercase>` in its own worktree |

## Goal

One paragraph: what is wrong or missing, for whom, and what "done" looks like. State the ruling it
rests on (the human or the seat, with the date).

## Acceptance (numbered, each checkable)

1. …
2. …
3. A `/orchestration-kit:falsify` record (at least one mutant per new guard) in the commit body.

## Fence

Files the row may touch (globs ok). Everything else is out of fence: stop and message the seat.

## Seam map (file:line, as measured at the base sha — verify upward)

- `path/to/file:123` — what lives there and why it matters
- …

## Gate

The class and command from `ORCHESTRATION.md` → Gate, run from INSIDE the worktree. Expected delta:
`<stage> +N tests`. Name any extra suites the change needs.

## Report protocol

- To the seat (SendMessage), never to a verifier or to the builder of another row.
- At RED (the failing guard, with numbers) and at GREEN-FINAL (sha · per-stage counts · falsify
  record · fill and window from `python3 scripts/ctx-fill.py <uuid>`).
- Questions and permission prompts → stop and message the seat. No deploy, no merge to main.
- Scratch and evidence (probes, logs, mutant outputs) → the evidence dir (ORCHESTRATION.md), never `/tmp`.
