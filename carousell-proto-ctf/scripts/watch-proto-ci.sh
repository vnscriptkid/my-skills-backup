#!/usr/bin/env bash
# Watch a cs-proto / grp-proto CI run and report only job state changes.
#
# Unlike `gh run watch` (which reprints the whole job tree every 3s and has produced
# 700KB+ of output), this prints one line per job state transition, then a verdict.
# It never fetches logs: on failure it names the failed job and leaves log inspection
# to you, so a passing run costs almost no output.
#
# Usage: watch-proto-ci.sh --branch <branch> [--repo carousell/cs-proto] [--service <name>]... [--timeout <sec>]
#        watch-proto-ci.sh --run <run-id> [--repo ...] [--service <name>]... [--timeout <sec>]
#        watch-proto-ci.sh --fixture testdata/<case>.json [--service <name>]...   # offline self-test
#
# Watching several services in one run? Repeat --service (--service a --service b);
# one watcher then covers the whole set, with a single exit code to act on. Do not
# start one watcher per service, and do not hand-roll a `gh run view` poll loop.
#
# Exit codes: 0 = all watched jobs succeeded, 1 = a watched job failed,
#             2 = timed out, 3 = usage/lookup error.
#
# Run testdata/run-tests.sh after changing the verdict logic.

set -uo pipefail

# `declare -A` (the seen-state map) is bash 4+. macOS ships bash 3.2 as /bin/bash,
# so a teammate running `bash watch-proto-ci.sh` gets a confusing parse error
# instead of a diagnosis. The shebang prefers a newer bash from PATH.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: needs bash 4+ (found $BASH_VERSION). On macOS: brew install bash" >&2
  exit 3
fi

REPO="carousell/cs-proto"
BRANCH=""
RUN_ID=""
SERVICES=()
TIMEOUT=1200
INTERVAL=20
FIXTURE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --run)     RUN_ID="$2"; shift 2 ;;
    --service) SERVICES+=("$2"); shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

# Fixture mode replaces the two `gh` calls with a saved `gh run view --json jobs`
# payload, so every verdict branch is exercisable offline in milliseconds instead
# of waiting ~10min for real CI. See testdata/README.md.
if [[ -n "$FIXTURE" ]]; then
  if [[ ! -f "$FIXTURE" ]]; then
    echo "error: fixture not found: $FIXTURE" >&2
    exit 3
  fi
  RUN_ID="fixture"
  INTERVAL=0
fi

if [[ -z "$RUN_ID" && -z "$BRANCH" ]]; then
  echo "error: pass --branch <branch> or --run <run-id>" >&2
  exit 3
fi

# Resolve the newest run for the branch. Right after a push the run may not exist yet,
# so retry rather than latching onto the previous (stale) run.
if [[ -z "$RUN_ID" ]]; then
  # Pin the run to the commit just pushed, so we don't latch onto the previous
  # (stale) run before CI registers the push. Only trust HEAD if the cwd is a
  # checkout of $REPO -- `git rev-parse HEAD` succeeds in any repo, and an
  # unrelated SHA would never match and silently degrade to "newest run".
  head_sha=""
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  repo_slug="${REPO#*/}"
  if [[ "$origin_url" == *"$repo_slug"* ]]; then
    head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  elif [[ -n "$origin_url" ]]; then
    echo "warning: cwd is not a $REPO checkout -- cannot pin the run to your pushed commit." >&2
    echo "         Run from the proto checkout, or pass --run <run-id>, to avoid picking a stale run." >&2
  fi
  for attempt in $(seq 1 10); do
    if [[ -n "$head_sha" ]]; then
      RUN_ID="$(gh run list --repo "$REPO" --branch "$BRANCH" --limit 20 \
        --json databaseId,headSha --jq \
        "[.[] | select(.headSha == \"$head_sha\")] | .[0].databaseId // empty" 2>/dev/null)"
    fi
    if [[ -z "$RUN_ID" ]]; then
      RUN_ID="$(gh run list --repo "$REPO" --branch "$BRANCH" --limit 1 \
        --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null)"
      # Without a SHA match we cannot tell a fresh run from the previous one; give CI
      # a chance to register the push before accepting it.
      if [[ -n "$head_sha" && $attempt -lt 4 ]]; then RUN_ID=""; fi
    fi
    [[ -n "$RUN_ID" ]] && break
    sleep 10
  done
fi

if [[ -z "$RUN_ID" ]]; then
  echo "error: no CI run found for branch '$BRANCH' in $REPO" >&2
  exit 3
fi

if [[ -n "$FIXTURE" ]]; then
  echo "fixture $FIXTURE"
else
  echo "run $RUN_ID  https://github.com/$REPO/actions/runs/$RUN_ID"
fi
# One alternation covering every --service, so a multi-service watch is a single
# watcher with a single exit code rather than N watchers to track and tear down.
service_pattern=""
if (( ${#SERVICES[@]} > 0 )); then
  service_pattern="$(IFS='|'; echo "${SERVICES[*]}")"
  echo "filtering jobs matching service(s): ${SERVICES[*]}"
fi

# Only these job types gate the Go code we need. Other jobs (java/js/swift/publish)
# are irrelevant, and the overall run conclusion reflects them too -- which is why
# the run-level status must not be used as the verdict.
#
# `init` is included because it gates everything: when a run is superseded or
# cancelled early, `init` is the only job carrying the `cancelled` state -- the
# rest merely `skipped`. Without it the verdict misreads a cancelled run as
# "no .proto files changed" and sends you looking in the wrong place.
relevant_filter='select(.name | test("/ init$|validation \\(|generation|decision"))'
if [[ -n "$service_pattern" ]]; then
  relevant_filter="$relevant_filter"' | select(.name | test("'"$service_pattern"'|decision|/ init$"))'
fi

# Every generation job in the run, ignoring --service. Used only to tell you which
# services the matrix actually expanded to, so a too-narrow --service is visible
# while you can still restart with a wider one -- one session discovered mid-watch
# that it needed four services and abandoned the script instead.
all_services_filter='.jobs[] | select(.name | test("generation \\(")) | .name'

# Sole reader of job state. Fixture mode swaps the source of the JSON and nothing
# else, so every branch below runs against the same code path production uses.
fetch_snapshot() {
  local jq_prog=".jobs[] | $relevant_filter | \"\(if (.conclusion // \"\") == \"\" then .status else .conclusion end)\t\(.name)\""
  if [[ -n "$FIXTURE" ]]; then
    jq -r "$jq_prog" < "$FIXTURE" 2>/dev/null
  else
    gh run view "$RUN_ID" --repo "$REPO" --json jobs --jq "$jq_prog" 2>/dev/null
  fi
}

# Distinct service names across the expanded generation matrix. The job name shape is
# `... / generation (<lang>, <service>, ..., server)`, so the service is field 2 of the
# parenthesised list.
fetch_all_services() {
  local names
  if [[ -n "$FIXTURE" ]]; then
    names="$(jq -r "$all_services_filter" < "$FIXTURE" 2>/dev/null)"
  else
    names="$(gh run view "$RUN_ID" --repo "$REPO" --json jobs --jq "$all_services_filter" 2>/dev/null)"
  fi
  sed -n 's/.*generation (\([^,)]*\), *\([^,)]*\).*/\2/p' <<< "$names" \
    | sed 's/^ *//; s/ *$//' | sort -u | paste -sd' ' -
}

# Only consulted when the matrix hasn't expanded; a fixture is a frozen instant,
# so treating it as completed stops the poll loop from spinning forever.
fetch_run_status() {
  if [[ -n "$FIXTURE" ]]; then
    echo "completed"
  else
    gh run view "$RUN_ID" --repo "$REPO" --json status --jq .status 2>/dev/null
  fi
}

declare -A seen
deadline=$(( SECONDS + TIMEOUT ))
snapshot=""
announced_matrix=""

while true; do
  snapshot="$(fetch_snapshot)"

  if [[ -z "$snapshot" ]]; then
    # Transient API hiccup, or the matrix has not expanded yet.
    if (( SECONDS >= deadline )); then echo "TIMED OUT after ${TIMEOUT}s"; exit 2; fi
    sleep "$INTERVAL"
    continue
  fi

  # Print only transitions, so the log stays short over a 10-minute run.
  while IFS=$'\t' read -r state name; do
    [[ -z "$name" ]] && continue
    if [[ "${seen[$name]:-}" != "$state" ]]; then
      printf '%6s  %s\n' "$state" "$name"
      seen[$name]="$state"
    fi
  done <<< "$snapshot"

  # Announce the matrix once, as soon as it expands. A --service narrower than the set
  # of services you actually need is otherwise invisible until the verdict, by which
  # point the cheap fix (restart with a wider --service) is no longer available.
  if [[ -z "$announced_matrix" ]] && grep -q 'generation (' <<< "$snapshot"; then
    expanded="$(fetch_all_services)"
    if [[ -n "$expanded" ]]; then
      echo "matrix expanded to: $expanded"
      if [[ -n "$service_pattern" ]]; then
        echo "  (watching only: ${SERVICES[*]} -- restart with more --service flags if you need others)"
      fi
      announced_matrix=1
    fi
  fi

  pending="$(awk -F'\t' '$1=="queued" || $1=="in_progress" || $1=="waiting" || $1==""' <<< "$snapshot")"

  # The generation jobs are a matrix that does not exist until `decision` completes.
  # Without this, an early snapshot containing only finished validation jobs looks
  # like a finished run and the script exits before any code is generated.
  decision_done="$(awk -F'\t' '$2 ~ /\/ decision$/ && ($1=="success" || $1=="skipped" || $1=="failure" || $1=="cancelled")' <<< "$snapshot")"
  has_generation="$(awk -F'\t' '$2 ~ /generation/' <<< "$snapshot")"

  if [[ -z "$pending" ]]; then
    if [[ -n "$decision_done" || -n "$has_generation" ]]; then
      break
    fi
    # Matrix not expanded yet -- keep polling rather than declaring victory, but
    # only while the run itself is still going. A finished run that never expanded
    # the matrix (eg. nothing to generate) must fall through to the verdict below.
    run_status="$(fetch_run_status)"
    [[ "$run_status" == "completed" ]] && break
  fi

  # A fixture is a single frozen instant -- polling it again returns the same
  # bytes forever, so a still-pending fixture must report the timeout verdict
  # after one pass rather than spinning until the real deadline.
  if [[ -n "$FIXTURE" ]]; then
    echo "TIMED OUT after ${TIMEOUT}s -- still pending:"
    echo "$pending"
    exit 2
  fi

  if (( SECONDS >= deadline )); then
    echo "TIMED OUT after ${TIMEOUT}s -- still pending:"
    echo "$pending"
    exit 2
  fi
  sleep "$INTERVAL"
done

echo "---"

failed="$(awk -F'\t' '$1=="failure" || $1=="cancelled" || $1=="timed_out"' <<< "$snapshot")"
generated="$(awk -F'\t' '$1=="success" && $2 ~ /generation \(/' <<< "$snapshot")"

if [[ -n "$failed" ]]; then
  # Separate real failures from siblings the runner cancelled as a consequence --
  # the cancelled ones are noise and point at the wrong service.
  real="$(awk -F'\t' '$1=="failure" || $1=="timed_out"' <<< "$snapshot")"
  collateral="$(awk -F'\t' '$1=="cancelled"' <<< "$snapshot")"
  if [[ -n "$real" ]]; then
    echo "FAILED:"
    echo "$real"
    [[ -n "$collateral" ]] && echo "(also cancelled as a knock-on: $(wc -l <<< "$collateral" | tr -d ' ') job(s))"
  else
    echo "CANCELLED (no job failed outright -- run may have been superseded or cancelled):"
    echo "$collateral"
  fi
  echo ""
  echo "To see why, inspect the logs of the failed job(s) -- see the skill's"
  echo "'Diagnosing a CI failure' section. Start with:"
  echo "  gh run view $RUN_ID --repo $REPO --log-failed"
  exit 1
fi

if [[ -z "$generated" ]]; then
  # A run whose meaningful jobs all skipped reports overall success but produces
  # no Go code -- eg. a branch-cleanup-only run, or a push touching no .proto files.
  echo "NO GO CODE GENERATED -- every generation job was skipped."
  echo "Check that the push actually changed .proto files on this branch."
  echo "$snapshot"
  exit 1
fi

echo "SUCCESS -- generation jobs completed:"
echo "$generated"
