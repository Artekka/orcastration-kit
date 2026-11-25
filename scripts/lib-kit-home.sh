#!/usr/bin/env bash
# lib-kit-home.sh (orcastration-kit): the ONE place that decides the kit's state home, sourced by every
# script that keeps state (gate-throttle, quiet-mode, seat-merge, lib-launch, lib-model-tag, sibling-shell).
# hooks/ctx-guard.py carries the same rule in python; tests/kit-home.test.sh pins both.
#
#   kit_home   prints ~/.orcastration-kit (it does not create it; callers mkdir what they need).
#
# Why a link and not a move (0.17.0 renamed the plugin id from the 0.16 spelling): every open tab runs a
# sibling-shell.sh loop that fixed its state folder when it started, and kit-init copied the scripts into each
# project, so 0.16 copies keep reading and writing ~/.orchestration-kit (the 0.16 folder). A move would leave a
# gap with no folder and would split the state between old and new copies, and a recycle hand-off written to
# one name would never reach a wrapper watching the other. So when only the 0.16 folder exists, the new name
# becomes a relative symlink to it in one step (ln -s is atomic; a racing twin's ln fails with EEXIST and
# harmlessly uses the link the winner made). Both names then lead to the same files, and the gate-throttle
# flocks stay correct because they lock the same inodes.
# Both real folders (someone made the new one by hand): the new one wins, with one warning on stderr
# (a marker file inside the new folder keeps it to one).
# Env overrides (KIT_RUNTIME_DIR, SIBLING_STATE_DIR, KIT_STATE_DIR, SEAT_MERGE_RUNTIME_DIR) are applied by the
# callers before they call kit_home, so an override never migrates anything.

kit_home() {
  local new="$HOME/.orcastration-kit" oldname=".orchestration-kit"   # the 0.16 folder name
  local old="$HOME/$oldname"
  if [ -e "$new" ] || [ -L "$new" ]; then
    if [ -d "$old" ] && [ ! -e "$new/.kit-home-both-warned" ] \
       && [ "$(cd "$new" 2>/dev/null && pwd -P)" != "$(cd "$old" 2>/dev/null && pwd -P)" ]; then
      echo "orcastration-kit: both ~/.orcastration-kit and the 0.16 folder ~/$oldname exist; using ~/.orcastration-kit (move anything you still need from the old one, then delete it)" >&2
      : > "$new/.kit-home-both-warned" 2>/dev/null
    fi
  elif [ -d "$old" ]; then
    if ln -s "$oldname" "$new" 2>/dev/null; then
      echo "orcastration-kit: state folder is now ~/.orcastration-kit (a link to the 0.16 folder ~/$oldname, so tabs started on 0.16 keep working)" >&2
    fi
  fi
  printf '%s' "$new"
}
