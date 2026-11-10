#!/usr/bin/env bash
# Runs SwiftLint's analyzer rules (the `analyzer_rules:` in .swiftlint.yml).
#
# `swiftlint lint` never runs analyzer rules: they need type information, which
# `swiftlint analyze` reads from a full compiler log. This script builds into a
# throwaway scratch path (so every file is compiled and logged, and .build is
# left alone), then runs each rule on its own: SwiftLint 0.65.1 crashes
# ("Attempted to read an unowned reference") when several analyzer rules run in
# one invocation.
#
#   scripts/swiftlint-analyze.sh          # report
#   scripts/swiftlint-analyze.sh --fix    # also apply correctable fixes (unused_import)
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Building with a compiler log…" >&2
swift build --build-tests -v --scratch-path "$work/build" >"$work/compile.log" 2>&1 \
  || { cat "$work/compile.log" >&2; exit 1; }

rules=$(awk '/^analyzer_rules:/{f=1;next} f&&/^  - /{print $2} f&&!/^  - /{f=0}' .swiftlint.yml)
status=0
for rule in $rules; do
  swiftlint analyze --quiet --compiler-log-path "$work/compile.log" --only-rule "$rule" "$@" || status=$?
done
exit $status
