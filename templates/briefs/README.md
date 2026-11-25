# Row briefs

One file per assigned row: `docs/orchestration/briefs/<ROW>.md`, made from `_TEMPLATE.md`. The
brief is the row's whole contract — goal · numbered acceptance · fence · seam map · base branch ·
gate · model · report protocol — so a fresh builder can start from it alone.

| who | does |
|---|---|
| seat | writes the brief, commits + pushes it, THEN sends the assign message naming the file |
| builder | `/orcastration-kit:orient-brief <ROW>`: the brief + the board banner arrive injected (the always-loaded CLAUDE.md comes with the session), sends READY, builds |
| verifier (READ) | reads the brief + the diff — the brief IS the contract; never the builder's reports |

- **Why a file and not a long message:** a fresh session otherwise spends 100K+ tokens orienting on
  a whole project to learn one row. The brief is the row; the lean orient is a few reads.
- **The brief is a hypothesis.** A builder who finds the code contradicts it corrects it upward and
  says so in the report.
- **A fix round appends** a `## Fix round <n>` section to the SAME file rather than a new brief.
- **Keep it contract-only.** A brief that narrates how the seat reasoned briefs its own verifiers.
- Older files here (seam maps, artifacts a row pointed at) predate the template and stay as they are.
