# shellcheck shell=bash
# scripts/lib-prompt-dialog.sh: the permission-prompt patterns and the dialog check, shared by scripts/bottleneck-watch.sh.
# Sourcing defines PROMPT_PATTERNS and prompt_dialog; it runs nothing.
#   source scripts/lib-prompt-dialog.sh; prompt_dialog "<pattern>" <<<"$screen"

# Panes that wait on a permission prompt. The ONE place for the patterns. "Do you want to proceed" was read from a live pane; the other
# three stems (make this edit / create / allow) are from memory of Claude Code's dialogs. A false flag costs one check, a miss costs hours.
# A pane quoting one of these in prose is a false positive that the CHECK in the flag line settles in one look.
PROMPT_PATTERNS=(
  'Do you want to proceed'
  'Do you want to make this edit'
  'Do you want to create'
  'Do you want to allow'
)
# A dialog, not prose that quotes it (a report and a board line quoted "Do you want to proceed" and drew two false flags): the
# pattern line must be followed within 6 lines by the first numbered option a permission dialog shows ("1. Yes", with or without the
# selector arrow). Case-sensitive on purpose. stdin = the pane's last screen, $1 = the pattern.
prompt_dialog() {
  awk -v pat="$1" '
    # (a) the phrase may wrap over up to 3 lines in a narrow pane, so each line is also joined with the one or two
    # before it (whitespace squeezed) and the dialog starts at the LAST line the phrase touches; (b) the options are "1. Yes", or a
    # numberless "Yes" line followed within 3 lines by a "No" line, or the sentence Claude Code prints when the pane is too short
    # to draw them (r1: anchored at the line start). The numberless form needs the selector "❯" on the Yes or the No line, and the
    # "1. Yes" line must end after "Yes" or a comma. STAYS OPEN: a prose line that is exactly "❯ 1. Yes" (or "❯ Yes" then "No ...")
    # under a quote still flags; one look at the CHECK line settles it.
    function squeeze(t) { gsub(/[[:space:]]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t); return t }
    { l[NR] = squeeze($0)
      j = l[NR]
      # A join counts only when the phrase is NOT already whole in an earlier piece, or the next line would re-trigger it.
      j2 = (NR > 1) ? squeeze(l[NR-1] " " j) : ""
      j3 = (NR > 2) ? squeeze(l[NR-2] " " j2) : ""
      if (index(j, pat)) seen = NR
      else if (j2 != "" && index(j2, pat) && !index(l[NR-1], pat)) seen = NR
      else if (j3 != "" && index(j3, pat) && !index(j2, pat) && !index(squeeze(l[NR-2] " " l[NR-1]), pat) && !index(l[NR-2], pat)) seen = NR }
    seen && NR > seen && NR <= seen + 6 {
      if ($0 ~ /^[[:space:]]*(❯|>)?[[:space:]]*1\.[[:space:]]+Yes(,.*)?[[:space:]]*$/) found = 1
      if ($0 ~ /^[[:space:]]*This terminal is too short\. Make it taller to choose Yes/) found = 1
      if ($0 ~ /^[[:space:]]*(❯[[:space:]]*)?Yes(,.*)?[[:space:]]*$/) { yes = NR; yarrow = ($0 ~ /❯/) }
      if (yes && NR > yes && NR <= yes + 3 && $0 ~ /^[[:space:]]*(❯[[:space:]]*)?No([^[:alnum:]]|$)/ && (yarrow || $0 ~ /❯/)) found = 1
      if (found) exit
    }
    END { exit !found }'
}
