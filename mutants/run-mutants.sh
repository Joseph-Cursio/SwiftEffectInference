#!/usr/bin/env bash
#
# Private mutation/regression runner for SwiftEffectInference (SwiftPM) — the
# effect lattice + purity inferrer, mutated and killed by the library's own tests.
#
# For each mutant in manifest.json: apply the patch, build the tests, run its
# named killer test via `swift test --filter` (SPM targets methods precisely, so
# the kill is attributed by construction), classify killed/survives/error,
# compare to the expected outcome, then revert. Prints a per-shape scorecard.
# Exit 0 iff every mutant matched its expectation.
#
# NOT a scored benchmark (no frozen answer key). A regression guard: it tells you
# when a change stops the property suites catching a bug shape they used to catch.
#
# Usage:  mutants/run-mutants.sh [mutant-id ...]      (no args = all)
# Written for macOS's stock bash 3.2 (no mapfile / associative arrays).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree is not clean — commit or stash before running mutants." >&2
  exit 2
fi

WANT=" $* "
want() { [ "$WANT" = "  " ] && return 0; case "$WANT" in *" $1 "*) return 0;; *) return 1;; esac; }

LOG="$(mktemp -d)"
RESULTS="$LOG/results.tsv"; : >"$RESULTS"
ROWS="$LOG/rows.tsv"
python3 - >"$ROWS" <<'PY'
import json
m = json.load(open("mutants/manifest.json"))
for x in m["mutants"]:
    print("\t".join([x["id"], x["patch"], x["expected"], x.get("shape",""), (x.get("test","") or "-")]))
PY

while IFS=$'\t' read -r id patch expected shape test; do
  [ -n "$id" ] || continue
  [ "$test" = "-" ] && test=""
  want "$id" || continue

  printf '\n-- %-30s [%s]  expect: %s\n' "$id" "$shape" "$expected"
  if ! git apply "$HERE/$patch" 2>"$LOG/$id.apply"; then
    printf '   APPLY FAILED (%s)\n' "$(tail -1 "$LOG/$id.apply" 2>/dev/null)"
    printf 'FAIL\t%s\t%s\t%s\tapply-failed\n' "$id" "$shape" "$expected" >>"$RESULTS"; continue
  fi

  if ! swift build --build-tests >"$LOG/$id.build" 2>&1; then
    outcome="error"
  else
    swift test --filter "$test" >"$LOG/$id.log" 2>&1
    [ $? -eq 0 ] && outcome="survives" || outcome="killed"
  fi
  git checkout -- . >/dev/null 2>&1

  if [ "$outcome" = "$expected" ]; then verdict="PASS"; else verdict="FAIL"; fi
  printf '   outcome: %-9s -> %s   (log: %s)\n' "$outcome" "$verdict" "$LOG/$id.log"
  printf '%s\t%s\t%s\t%s\t%s\n' "$verdict" "$id" "$shape" "$expected" "$outcome" >>"$RESULTS"
done <"$ROWS"

python3 - "$RESULTS" "$LOG" <<'PY'
import sys, collections
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
per = collections.defaultdict(lambda: [0, 0]); npass = nfail = 0
for verdict, mid, shape, expected, outcome in rows:
    per[shape][1] += 1
    if verdict == "PASS": per[shape][0] += 1; npass += 1
    else: nfail += 1
print("\n================ scorecard ================")
for shape in sorted(per):
    p, t = per[shape]; print(f"  {shape:<26} {p}/{t}")
print("------------------------------------------")
for verdict, mid, shape, expected, outcome in rows:
    print(f"  {verdict}  {mid:<30} expected={expected:<9} outcome={outcome}")
print(f"  TOTAL: {npass} pass, {nfail} fail")
print(f"  logs: {sys.argv[2]}")
print("==========================================")
sys.exit(1 if nfail else 0)
PY
