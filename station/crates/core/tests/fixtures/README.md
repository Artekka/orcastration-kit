# core test fixtures

Tests read ONLY these files, never the live `~/.claude/projects` logs.

Every fixture here is **synthetic**: written by hand, or generated from invented values only. No line
is copied, scrambled or otherwise derived from a real session log. Record kinds and field names
follow Claude Code's log format; every id, uuid, timestamp, path, name and word is made up (times
are round values or fall on an invented 2030 date). `scripts/real-data-check.py` checks that no
id- or timestamp-like value in the tree is a real value from the local Claude logs.

| file | what it is | what it covers |
|---|---|---|
| `synthetic_session.jsonl` | 161 invented records in the shape of one kit sibling's session: "Ada" runs `/orchestration-kit:orient`, makes tool calls, reports READY to "Lead", then gets a task from Lead and ends mid-turn. Ids are invented uuids and `toolu_`/`msg_` ids; the parent/prompt/tool-pairing links between records are consistent | identity records (agent-name, mode, permission-mode, custom-title, session-owner), attachments, api-request*, data-flow-records, queue-operation, last-prompt, tools-used, file-history-snapshot, slash command, isMeta skill text, redacted thinking / tool_use / text, tool_result (string and list content, two results arriving out of order), turn_duration, a peer `<cross-session-message>`; ends mid-turn |
| `synthetic_zoo.jsonl` | hand-written, short invented ids (`z-01` …) | human text + image, task-notification, `<agent-message>` hand-back, away_summary, compact_boundary, compact summary, informational, local_command, bridge_status, a slash-command record, local-command caveat, an unknown block type, an interrupt, a duplicate uuid, an unknown record type, a truncated (malformed) line, a non-object line, an api-request-blob |
| `synthetic_image_refs.jsonl` | five invented records; every base64 image is a tiny generated image (4×2 PNG / JPEG) | a human message with 2 PNG + 1 JPEG pasted; a `Read` of a `.png` and its `tool_result` with one image part; a subagent `Bash` naming two absolute `.png` paths and a relative `mini.png` after a `cd`; an `api-request-blob` holding image blocks (must yield nothing) |
| `synthetic_images.jsonl` | hand-written | `Write` / `Edit` of image files (upper-case extension, relative path), a Windows `D:\…` path, a Bash command with globs / braces / variables (rejected) next to `~/`, `./…/../` and quoted paths, a missing file's error result, an image result arriving before its call, malformed image blocks (no source, string source, non-string type, url source) |
| `synthetic_pages.jsonl` | hand-written in the shape of the Artifact tool's calls and results (`file_path`/`description`/`icon` input; "Published … at https://claude.ai/artifact/<id> (Version N, version id …)"); page ids, titles and paths invented | publish without and with a title, republish of the same page (Version 2), quickstart whose result names type links, a refused publish (no URL), an errored publish, a `/code/artifact/` page, delete of one asset (page stays), delete of a page, a result before its call, create-from-type (result names the type link too), list/read/open/pin |
| `synthetic_home.jsonl` | hand-written: a session launched in the home folder (`cwd` `/home/user`, slug `-home-user`), no agent name or custom title | the default `~ (home)` project claims it; an unnamed session labelled by its first human line (long enough to be cut); one page published twice (Version 1, Version 2) |

The restart test derives a second session from `synthetic_session.jsonl` in code (new session id,
timestamps moved one hour later), so no other agent's log is needed.
