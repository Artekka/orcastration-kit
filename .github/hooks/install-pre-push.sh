#!/usr/bin/env bash
# Install (or remove) the opt-in pre-push secret scan for this repo. Nothing installs it for you.
#   bash .github/hooks/install-pre-push.sh              install; refuses to replace a different hook
#   bash .github/hooks/install-pre-push.sh --force      replace an existing pre-push hook (kept as pre-push.bak)
#   bash .github/hooks/install-pre-push.sh --uninstall  remove it (only if it is this hook)
# It honors core.hooksPath. The hook needs gitleaks on PATH.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/pre-push"
mode=install
case "${1:-}" in
  "") ;;
  --force) mode=force ;;
  --uninstall) mode=uninstall ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1 (see --help)" >&2; exit 64 ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not inside a git repository" >&2; exit 1; }
HOOKS="$(git rev-parse --path-format=absolute --git-path hooks)"
DEST="$HOOKS/pre-push"

if [ "$mode" = uninstall ]; then
  if [ ! -e "$DEST" ]; then echo "no pre-push hook installed"; exit 0; fi
  if cmp -s "$SRC" "$DEST"; then rm -f "$DEST"; echo "removed $DEST"; exit 0; fi
  echo "$DEST is a different hook; left it in place" >&2; exit 1
fi

if [ -e "$DEST" ] && ! cmp -s "$SRC" "$DEST"; then
  if [ "$mode" != force ]; then
    echo "$DEST already exists and is a different hook; rerun with --force to replace it (it is kept as pre-push.bak)" >&2
    exit 1
  fi
  mv -f "$DEST" "$DEST.bak"; echo "kept the old hook as $DEST.bak"
fi
mkdir -p "$HOOKS"
# a copy, not a symlink: a later checkout of another branch cannot change what runs on push
cp "$SRC" "$DEST"; chmod +x "$DEST"
echo "installed $DEST"
command -v gitleaks >/dev/null 2>&1 || echo "note: gitleaks is not on PATH yet; the hook stops every push until it is (https://github.com/gitleaks/gitleaks#installing)"
