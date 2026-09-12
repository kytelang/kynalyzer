#!/usr/bin/env bash
# Gate for kynalyzer: build, run the unit tests, and smoke the cross-compile targets. Exits non-zero on any
# failure. Needs the Kyte compiler checked out as a SIBLING at ../kyte (override with -Dkyte-src=...), and
# `zig` (0.16.0) on PATH. Run from the repo root.
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
fail=0
step() { echo; echo ">>> $*"; }

# Allow a different compiler-source path (e.g. a mono-repo where it is ../lang/src/root.zig).
KYTE_SRC_ARG=""
if [ -n "${KYTE_SRC:-}" ]; then KYTE_SRC_ARG="-Dkyte-src=${KYTE_SRC}"; fi

step "build (host)"
zig build $KYTE_SRC_ARG || fail=1

if [ $fail -eq 0 ]; then
  step "unit tests (zig build test)"
  zig build test $KYTE_SRC_ARG || fail=1
fi

if [ $fail -eq 0 ]; then
  step "cross-compile smoke (all targets)"
  zig build cross $KYTE_SRC_ARG || fail=1
fi

echo
if [ $fail -eq 0 ]; then echo "GATE PASS  kynalyzer"; else echo "GATE FAIL  kynalyzer"; fi
exit $fail
