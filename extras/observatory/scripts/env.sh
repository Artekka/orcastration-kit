# Observatory's own Rust toolchain. Source before any cargo command:  . scripts/env.sh
# Toolchain root: $OBSERVATORY_RUST_DIR, default ~/observatory-rust (written <rust dir> below). It holds
# rustup, cargo and the per-tree target dirs; keep it apart from any other project's toolchain.
#
# Target dir: ONE PER TREE. Worktrees must never share a cargo target dir: cargo's unit hash does not
# include the workspace path and freshness is by mtime, so a tree whose sources are older than another
# tree's build silently runs THAT tree's binaries (repro: main's 12-test fixtures_test ran a sibling's
# 14-test binary). The dir is derived from the git toplevel of the CURRENT directory (any subdir works;
# outside a repo, the tree this file lives in):
#   <rust dir>/targets/<tree basename>-<first 8 hex of sha256(toplevel path)>
#
# Override: a CARGO_TARGET_DIR the caller already set is RESPECTED (it survives scripts/gate.sh, which
# sources this file, and gate-throttle) when it lies OUTSIDE <rust dir>; it is normalized
# (realpath -m: symlinks, `..`, `//`, relative paths) and exported absolute. Any value that resolves
# INSIDE <rust dir> other than this tree's own dir is REFUSED (the old shared target, another
# tree's dir, anything else there), as is a literal unexpanded `~`. On refusal CARGO_TARGET_DIR is
# unset and env.sh fails: exit 1 in a script, return 1 in an interactive shell (gate.sh stops either
# way). Usual cause: a shell that sourced this in another tree. Fix: `unset CARGO_TARGET_DIR`.
# The resolved dir is created (mkdir -p), so callers may write into it before cargo runs.
#
# Disk: each tree pays one full build (~2.7 GB debug for the workspace on 2026-11-23).
# Cleanup after removing a worktree:  ls <rust dir>/targets  then  rm -rf <rust dir>/targets/<name>-<hash>
_obs_rust=${OBSERVATORY_RUST_DIR:-$HOME/observatory-rust}
export RUSTUP_HOME=$_obs_rust/rustup
export CARGO_HOME=$_obs_rust/cargo
export PATH=$CARGO_HOME/bin:$PATH

_obs_tree=$(git rev-parse --show-toplevel 2>/dev/null) ||
  _obs_tree=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
_obs_base=$(realpath -m -- "$_obs_rust")
_obs_own=$(realpath -m -- "$_obs_base/targets/$(basename "$_obs_tree")-$(printf %s "$_obs_tree" | sha256sum | cut -c1-8)")
_obs_why=
if [ -z "${CARGO_TARGET_DIR:-}" ]; then
  CARGO_TARGET_DIR=$_obs_own
else
  case "$CARGO_TARGET_DIR" in
    "~"*) _obs_why="it starts with a literal ~ (not expanded)" ;;
    *)
      _obs_norm=$(realpath -m -- "$CARGO_TARGET_DIR")
      if [ "$_obs_norm" = "$_obs_own" ]; then
        CARGO_TARGET_DIR=$_obs_own
      else
        case "$_obs_norm/" in
          "$_obs_base/"*) _obs_why="it resolves to $_obs_norm, inside $_obs_base but not this tree's own dir ($_obs_own)" ;;
          *) CARGO_TARGET_DIR=$_obs_norm ;;
        esac
      fi
      ;;
  esac
fi
if [ -n "$_obs_why" ]; then
  echo "env.sh: REFUSED CARGO_TARGET_DIR=$CARGO_TARGET_DIR: $_obs_why. Run: unset CARGO_TARGET_DIR" >&2
  unset CARGO_TARGET_DIR _obs_why _obs_tree _obs_base _obs_own _obs_norm _obs_rust
  case $- in *i*) return 1 ;; *) exit 1 ;; esac
fi
export CARGO_TARGET_DIR
mkdir -p "$CARGO_TARGET_DIR"
unset _obs_why _obs_tree _obs_base _obs_own _obs_norm _obs_rust
