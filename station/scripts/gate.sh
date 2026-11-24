#!/usr/bin/env bash
# Orcastration Station gate: clean tree (private denylist, if any), real data (local Claude logs, if any), fmt,
# clippy, tests, Windows cross-build check. Last line is the pass proof:
#   GATE PASS (<N> tests)
# Usage: bash scripts/gate.sh [--release]   (--release also builds the release .exe)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/env.sh || { echo "GATE FAIL: env.sh refused"; exit 1; }
echo "gate tree: $(pwd) @ $(git rev-parse --short HEAD 2>/dev/null || echo no-commit)"
echo "gate target: $CARGO_TARGET_DIR"
fail() { echo "GATE FAIL: $1"; exit 1; }
python3 scripts/clean-tree.py || fail "clean tree (a denylisted term is in the shippable tree)"
python3 scripts/real-data-check.py || fail "real data (a value from a real Claude log or commit is in the shippable tree)"
cargo fmt --all -- --check || fail "cargo fmt"
cargo clippy --locked --workspace --all-targets -- -D warnings || fail "clippy"
out=$(cargo test --locked --workspace 2>&1); rc=$?
echo "$out"
[ $rc -eq 0 ] || fail "cargo test (exit $rc)"
echo "$out" | grep -E '^test result:' | grep -vqE 'ok\. [0-9]+ passed; 0 failed' && fail "a test result line is not clean"
n=$(echo "$out" | grep -E '^test result: ok\.' | sed -E 's/.*ok\. ([0-9]+) passed.*/\1/' | paste -sd+ | bc)
[ "${n:-0}" -gt 0 ] || fail "no tests ran"
cargo check --locked --workspace --target x86_64-pc-windows-gnu || fail "windows cross-check"
if [ "${1:-}" = --release ]; then cargo build --locked --workspace --release --target x86_64-pc-windows-gnu || fail "release build"; fi
echo "GATE PASS ($n tests)"
