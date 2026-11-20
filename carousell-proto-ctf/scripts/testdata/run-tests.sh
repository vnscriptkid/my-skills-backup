#!/usr/bin/env bash
# Exercise every verdict branch of watch-proto-ci.sh against recorded CI payloads.
# Runs offline in ~1s; no gh, no network, no waiting for real CI.
#
# Usage: testdata/run-tests.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
WATCHER="../watch-proto-ci.sh"

pass=0
fail=0

# check <fixture> <expected-exit> <expected-substring> [extra args...]
check() {
  local fixture="$1" want_code="$2" want_text="$3"; shift 3
  local out code
  out="$("$WATCHER" --fixture "$fixture" "$@" 2>&1)"
  code=$?

  if [[ $code -eq $want_code && "$out" == *"$want_text"* ]]; then
    printf 'PASS  %-24s exit=%d  %s\n' "$fixture" "$code" "$want_text"
    (( pass++ ))
  else
    printf 'FAIL  %-24s exit=%d (want %d)\n' "$fixture" "$code" "$want_code"
    printf '      wanted text: %s\n' "$want_text"
    printf '      --- output ---\n%s\n      --------------\n' "$out"
    (( fail++ ))
  fi
}

# Recorded from real cs-proto runs (see README.md for provenance).
check success-generated.json     0 "SUCCESS -- generation jobs completed"
check fail-validation.json       1 "FAILED:"
check fail-decision.json         1 "FAILED:"
check cancelled-superseded.json  1 "CANCELLED"
check all-skipped.json           1 "NO GO CODE GENERATED"
check matrix-expanding.json      2 "TIMED OUT"

# --service narrows the matrix to one service; `decision` is always kept.
check success-generated.json     0 "SUCCESS" --service listing-quota

# A service with no jobs in the run must not report success.
check success-generated.json     1 "NO GO CODE GENERATED" --service nonexistent-service

# Repeated --service is one watcher over the union, not the last flag winning.
check multi-service.json         0 "generation (proto/subscriptions" --service content-feed --service subscriptions
check multi-service.json         0 "generation (proto/listing-visualizer" --service listing-visualizer

# The matrix notice names every expanded service, so a too-narrow --service is
# visible while restarting with a wider one is still cheap.
check multi-service.json         0 "matrix expanded to: content-feed content-feed-gw listing-quota listing-visualizer subscriptions" --service subscriptions

# A service the run never generated stays absent from the verdict even when a
# sibling --service succeeds.
check multi-service.json         0 "SUCCESS" --service subscriptions --service nonexistent-service

echo "---"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
