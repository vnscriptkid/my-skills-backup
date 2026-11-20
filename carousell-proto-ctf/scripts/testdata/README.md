# watch-proto-ci.sh fixtures

Recorded `gh run view --json jobs` payloads, one per verdict branch. They let
`watch-proto-ci.sh` be exercised offline in ~1s instead of pushing a branch and
waiting ~10min for real CI.

```bash
testdata/run-tests.sh                                   # all branches
../watch-proto-ci.sh --fixture testdata/<case>.json     # one case
```

Fixture mode swaps only where the JSON comes from -- the verdict logic is the
same code path production runs.

## Cases

| Fixture | Exit | Covers |
|---|---|---|
| `success-generated.json` | 0 | generation jobs succeeded |
| `fail-validation.json` | 1 | a `validation` job failed |
| `fail-decision.json` | 1 | `decision` failed, matrix never expanded |
| `cancelled-superseded.json` | 1 | run cancelled at `init`, everything else skipped |
| `all-skipped.json` | 1 | `decision` succeeded but nothing generated |
| `matrix-expanding.json` | 2 | jobs still `queued`/`in_progress` |
| `multi-service.json` | 0 | repeated `--service`, and the matrix-expanded notice |

All except `all-skipped.json` and `multi-service.json` are verbatim from real
`carousell/cs-proto` runs (2026-07-31), trimmed to `{name, status, conclusion}`.
`all-skipped.json` is derived from `success-generated.json` by dropping the
`generation (` jobs and marking the rest skipped -- the shape a
branch-cleanup-only run produces, which didn't appear in recent history.

`multi-service.json` is synthesised on the four-service shape of a real
listing-tiers run: `content-feed`, `content-feed-gw`, `listing-visualizer`,
`subscriptions`, plus an unrelated `listing-quota` in the same matrix. The
recorded single-service runs cannot cover multi-service watching at all, and the
unrelated service is what makes the "watching only" notice meaningful.

## `--service` matches substrings

The filter is a jq `test()` regex, so `--service content-feed` also matches
`content-feed-gw`. That is usually what you want; when it isn't, anchor it --
`--service 'content-feed,'` matches the job-name comma that follows the exact
service. `multi-service.json` has both names so this stays visible.

## Why `init` is in the filter

`cancelled-superseded.json` caught a real bug. In a superseded run, `init` is the
only job carrying `cancelled` -- everything else is merely `skipped`. The filter
originally matched only `validation (`, `generation`, `decision`, so the
cancellation was invisible and the script reported "NO GO CODE GENERATED -- check
that the push actually changed .proto files", sending you to the wrong place.
Keep `/ init$` in `relevant_filter`.

## Re-recording

```bash
gh run view <run-id> --repo carousell/cs-proto --json jobs \
  | jq '{jobs: [.jobs[] | {name, status, conclusion}]}' > testdata/<case>.json
```

Add a fixture whenever CI surprises you in a new way -- that is what stops the
same surprise costing another debugging session.
