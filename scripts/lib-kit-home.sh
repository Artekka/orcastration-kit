#!/usr/bin/env bash
# lib-kit-home.sh (orcastration-kit): the ONE place that decides the kit's state home, sourced by every
# script that keeps state (gate-throttle, quiet-mode, seat-merge, lib-launch, lib-model-tag, sibling-shell).
# hooks/ctx-guard.py carries the same rule in python; tests/kit-home.test.sh pins both.
#
#   kit_home   prints ~/.orcastration-kit, or prints one line on stderr and returns 1 when the state folder cannot be
#              used (callers stop on that non-zero status). On a fresh install it makes the folder and links the 0.16
#              name to it; on every call it makes that link again when it is missing.
#   kit_home_check / kit_home_two_folders   read-only verdicts (see each function).
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
# A dangling link at the new name (its target was moved or deleted): only that link is removed, the 0.16 folder is made
# again if it is gone, and the new name links to it, with one line. Never a second real folder: an old 0.16 copy of
# gate-throttle/quiet-mode/seat-merge in a project re-creates the 0.16 folder on its own, and two real folders would be
# two throttle slot sets. Anything else at the new name that
# is not a folder (a regular file, a link to a file) is never touched: kit_home fails, so no caller runs on a path that
# cannot hold state (0.17.0 READ: `quiet-mode.sh on` printed a mkdir error and exited 0 with quiet mode still OFF).
# Env overrides (KIT_RUNTIME_DIR, SIBLING_STATE_DIR, KIT_STATE_DIR, SEAT_MERGE_RUNTIME_DIR) are applied by the
# callers before they call kit_home, so an override never migrates anything.

# kit_home_check: the same verdict as kit_home, with NO change on disk (dry runs and launchers call it before they
# touch anything). 0 = kit_home will work; else one line and 1. Broken: the new name is not a folder (and not a dangling
# link kit_home can heal), or the 0.16 path exists but is not a folder (a file, a dangling link): kit_home would have to
# remove or replace something it does not own.
kit_home_check() {
  local new="$HOME/.orcastration-kit" oldname=".orchestration-kit"   # the 0.16 folder name
  local old="$HOME/$oldname"
  if { [ -e "$old" ] || [ -L "$old" ]; } && [ ! -d "$old" ]; then
    echo "orcastration-kit: the 0.16 folder path ~/$oldname is not a folder (a file or a broken link); move it away, then run this again" >&2
    return 1
  fi
  if [ -L "$new" ] && [ ! -e "$new" ]; then return 0; fi
  if [ -e "$new" ] && [ ! -d "$new" ]; then
    echo "orcastration-kit: ~/.orcastration-kit is not a folder (a file or a broken link); move it away, then run this again" >&2
    return 1
  fi
  return 0
}

# kit_home_two_folders: 0 when both names are real, different folders (the C shape: someone made the new one by hand, or a
# 0.16 copy of a script ran while the 0.16 name's link was missing). No merge: the new one is used; callers warn.
kit_home_two_folders() {
  local new="$HOME/.orcastration-kit" old="$HOME/.orchestration-kit"   # the 0.16 folder name
  [ -d "$new" ] && [ -d "$old" ] && [ "$(cd "$new" 2>/dev/null && pwd -P)" != "$(cd "$old" 2>/dev/null && pwd -P)" ]
}

kit_home() {
  local new="$HOME/.orcastration-kit" oldname=".orchestration-kit"   # the 0.16 folder name
  local old="$HOME/$oldname" gone
  kit_home_check || return 1   # a broken shape: one line, nothing on disk changes
  if [ -L "$new" ] && [ ! -e "$new" ]; then
    gone="$(readlink "$new" 2>/dev/null)"
    # Re-checked right before rm: only a link whose target is still missing is removed (rm without -r never removes a folder).
    if [ -L "$new" ] && [ ! -e "$new" ]; then rm -f -- "$new" 2>/dev/null; fi
    mkdir -p "$old" 2>/dev/null           # gone (or never there): made again, so both names stay one folder
    ln -s "$oldname" "$new" 2>/dev/null   # EEXIST = a racing twin healed it first; the check below decides
    echo "orcastration-kit: ~/.orcastration-kit was a link to a missing folder ($gone); it links to the 0.16 folder ~/$oldname again" >&2
  elif [ -e "$new" ]; then
    if kit_home_two_folders && [ ! -e "$new/.kit-home-both-warned" ]; then
      echo "orcastration-kit: both ~/.orcastration-kit and the 0.16 folder ~/$oldname exist; using ~/.orcastration-kit (move anything you still need from the old one, then delete it)" >&2
      : > "$new/.kit-home-both-warned" 2>/dev/null
    fi
  elif [ -d "$old" ]; then
    if ln -s "$oldname" "$new" 2>/dev/null; then
      echo "orcastration-kit: state folder is now ~/.orcastration-kit (a link to the 0.16 folder ~/$oldname, so tabs started on 0.16 keep working)" >&2
    fi
  else
    # A fresh install: the new name is the real folder, and the 0.16 name links to it (below), so a 0.16 copy of a script
    # that runs later (its own mkdir -p on the 0.16 path) lands in this same folder instead of making a second one.
    mkdir -p "$new" 2>/dev/null \
      && echo "orcastration-kit: made the state folder ~/.orcastration-kit; the 0.16 folder name ~/$oldname links to it, so 0.16 copies of the scripts share it" >&2
  fi
  # Re-link on every call: a real new folder and nothing at the 0.16 path -> the 0.16 name links to it again (it may have
  # been deleted). A failed link is not fatal (HOME cannot hold links): say so, keep working.
  if [ -d "$new" ] && [ ! -L "$new" ] && [ ! -e "$old" ] && [ ! -L "$old" ]; then
    ln -s ".orcastration-kit" "$old" 2>/dev/null \
      || echo "orcastration-kit: could not link the 0.16 folder name ~/$oldname to ~/.orcastration-kit; a 0.16 copy of a script would make its own folder (run /orcastration-kit:kit-init in each project to refresh the copies)" >&2
  fi
  # Something at the new name that is not a folder cannot hold state: say so and fail (it is left as it is).
  if { [ -e "$new" ] || [ -L "$new" ]; } && [ ! -d "$new" ]; then
    echo "orcastration-kit: ~/.orcastration-kit is not a folder (a file or a broken link); move it away, then run this again" >&2
    return 1
  fi
  printf '%s' "$new"
}
