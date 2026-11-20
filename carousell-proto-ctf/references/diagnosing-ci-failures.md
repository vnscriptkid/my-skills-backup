# Diagnosing a cs-proto / grp-proto CI failure

Only fetch logs once `watch-proto-ci.sh` reports a failure. Identify the genuinely failed job first: when one job fails its siblings are marked `cancelled`, so the `cancelled` ones are collateral and point at the wrong service. The script already separates these.

Try in this order:

1. **`gh run view <run-id> --repo carousell/cs-proto`** -- plain, no flags. Breaking-change and validation errors show up free in the ANNOTATIONS section, with file and line (`...listingquota_checker.proto#84`), for ~3.7KB. Ignore the `Node.js 20 is deprecated` / `set-output` annotations; they are on every run. Almost always enough -- try this before `--log-failed`, which is ~100x larger.
2. **`gh run view <run-id> --repo carousell/cs-proto --log-failed`** -- for everything else. This is ~400KB of runner boilerplate, so always filter it. Every line is prefixed `<job name>\tUNKNOWN STEP\t<timestamp>`:

```bash
gh run view <run-id> --repo carousell/cs-proto --log-failed 2>/dev/null \
  | grep -aE '##\[error\]|^Error:|validation failed|Previously present|pii_classification|\.proto:[0-9]+' \
  | cut -c1-400 | head -40
```

Use `grep -a` -- the logs contain ANSI escapes and grep may treat them as binary. If `--log-failed` prints `failed to get run log: stream error: stream ID 1; CANCEL`, just retry; it's intermittent, and it exits 0, so a pipeline can look like "no errors found" when the fetch simply failed.

## Known failure classes

| Error | Cause / fix |
|---|---|
| `Previously present field "2" with name "ccid" on message "X" was deleted.` / `Previously present enum/message/RPC "X" was deleted from package "Y"` / `buf found N breaking changes.` | Fails the `validation` job. Usually a stale branch, not your change -- see below. If it really is your change, that's a breaking change and needs discussion. |
| `Error: validation failed` with a `<file>.proto:<line>` line mentioning `pii_classification` | A field whose *name* matches a PII pattern needs an annotation. Reproduce and fix locally instead of guessing -- `devctl proto validation --file proto/<service> --base_path proto` prints the same lines in ~1s. Annotate only the fields it names. The log prints the *suggested* line, not your current one, so don't conclude CI is reading a different file; and its enum guess is often wrong (`created_by` / `account_id` / `country` are usually `NOT_PII`). See `pii-annotations.md`. |
| `##[error]Could not clone the destination repository` | Check the line just above it. If `fatal: Remote branch <b> not found in upstream origin`, the branch was deleted (usually the PR merged) while the job was still running -- re-running can never succeed; use the merged code via `@latest` instead. Otherwise it's a transient infra flake: re-run the job. |
| Buf lint errors | Fix in the proto and push again. Catch these before pushing with `./lint.sh --service <service-name>`. |

## "All my generation jobs were skipped"

Generation is gated on validation passing, and the job matrix is built only from services
that validated. So a validation failure means your `generation (...)` jobs never run and
report `skipped` -- with no error of their own. `skipped` generation jobs are a symptom;
find the failed `validation (...)` job and fix that.

The failing service may not even be yours: if another service in the same push fails
validation, the matrix can come back without your entry.

## Errors in protos you didn't touch

If the deleted symbols belong to a service unrelated to your change, your branch is stale relative to master -- the buf breaking check compares against a master that has since removed those messages. This is easy to misdiagnose as a problem with your own change. Merge master and push again:

```bash
git fetch origin master && git merge origin/master --no-edit && git push origin <branch-name>
```

## Checking jobs by hand

If you need to inspect job state without the script, query jobs directly rather than watching -- ~370 bytes instead of hundreds of KB:

```bash
gh run view <run-id> --repo carousell/cs-proto --json jobs \
  --jq '.jobs[] | select(.name | contains("<service>")) | "\(if (.conclusion // "") == "" then .status else .conclusion end)\t\(.name)"'
```

`gh` returns `conclusion: ""` -- an empty string, not `null` -- for in-flight jobs, so `.conclusion // .status` silently yields `""` and makes a running job look finished. Hence the explicit `if` above.

Only the generation jobs gate the Go code (note client has two `false`s, server one):

```
main / generation (proto/<dir>, <service>, false, false, client)
main / generation (proto/<dir>, <service>, false, server)
```
