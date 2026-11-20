---
name: carousell-proto-ctf
description: Use when exploring protos or making protobuf changes in Carousell's CTF proto system (cs-proto / grp-proto repos), implementing a gRPC endpoint (either server or client), understanding a service's proto contract, bumping a cs-proto-gen-go version in go.mod, resolving a go.mod proto version conflict, or when a user mentions a proto branch, cs-proto, or cs-proto-gen-go.
---

# CTF Proto Management

## Background info

- `.proto` files live in `github.com/carousell/cs-proto/`, or `github.com/carousell/grp-proto/` for foundational services.
- A CI generates Go code from the protos and pushes it to `github.com/carousell/cs-proto-gen-go/` (or `grp-proto-gen-go/`). That repo hosts many Go modules, one set per service. Branch names in `cs-proto-gen-go` mirror those in `cs-proto`.
- Go backend services import the relevant modules. Eg. for `merchant-invoice`:
  - `github.com/carousell/cs-proto-gen-go/merchant-invoice/server/public` - service implementations; only merchant-invoice imports this
  - `github.com/carousell/cs-proto-gen-go/merchant-invoice/client/public` - other services import this to call merchant-invoice's gRPC APIs
  - Packages beyond `public` exist, eg. `common`, `management`, `internalapis` (`.../server/common`).

## Getting a proto version into go.mod

**Never look up a version number. Fetch by `@latest` or `@<branch-name>` and let the toolchain resolve it.**

```bash
cd <the service repo> && go get github.com/carousell/cs-proto-gen-go/<svc>/<pkg>@latest                    # on master
cd <the service repo> && GOPROXY=direct go get github.com/carousell/cs-proto-gen-go/<svc>/<pkg>@<branch>   # feature branch
```

- `@latest` for anything merged to cs-proto master. There is never a reason to pick an older release.
- `@<branch>` for a feature branch. Use the cs-proto branch name verbatim, slashes and all.
- **`GOPROXY=direct` is mandatory for a branch** -- branches are not in the internal goproxy. Without it, any branch ref is rejected before a single network call.
- **Read the module paths out of the service's go.mod and use them verbatim -- don't construct them.** `grep cs-proto-gen-go go.mod`. The module is `.../listing-quota/server`; `public` is a *package inside* it, not a module, so `.../listing-quota/server/public` fails with `not a known dependency`.
- Keep the `cd` in the same command. The shell cwd resets between commands, and `go get` outside a module fails with `'go get' is no longer supported outside a module.`
- Repeat for each cs-proto-gen-go module the service requires that lives on your branch.

### Do not hand-resolve versions

Each of these has cost 2-15 minutes in real sessions and produced wrong conclusions:

- `go list -m -versions` to hunt for a version. **It lists numbered tags only -- branch pseudo-versions never appear**, so its silence proves nothing. It also prints ~100 lines of noise. It has no use in this workflow.
- Reading a pseudo-version off `gh api .../branches/<b>`, a `cs-proto-gen-go` checkout, or the CI logs (it isn't printed there), then pasting it into go.mod.
- Fetching in a scratch module to learn the version string, then hand-editing go.mod. **Never hand-edit go.sum hashes.**
- The GitHub MCP/CLI for any cs-proto question. It 404s on cs-proto entirely -- PRs, commits, and code search -- and its empty results read as "doesn't exist".
- Adding a `replace` directive for a cs-proto-gen-go module as a first move. It's a genuine last resort for one specific blocker -- see "`replace` for a cs-proto-gen-go module" below -- never the opening play.

(`go list -m -versions` is the useless one. Plain `go list -m <mod>@<branch>` is fine and resolves a branch correctly, as long as `GOPROXY=direct` is set.) If you want a branch's pseudo-version without touching go.mod:

```bash
GOPROXY=direct go list -m github.com/carousell/cs-proto-gen-go/<svc>/<pkg>@<branch>
```

### These do NOT mean "the code isn't published yet"

Every row below has been misread as "the generated Go doesn't exist", leading to invented CI theories, false blockers escalated to the user, and wrong facts written to project memory. Check here before concluding anything is missing:

| What you saw | What it actually means |
|---|---|
| `invalid version: version "feat/x" invalid: disallowed version string` | You omitted `GOPROXY=direct`. Nothing was looked up -- the ref was rejected client-side. Slashes in branch names are fine. Applies to `go get` and `go list` alike. |
| `go get @<branch>` printed **nothing at all** | Success, and a no-op: go.mod is already at that branch's HEAD. Not a failure. |
| `go: downgraded <mod> v0.0.100 => v0.0.99-0.2026...` | Normal and expected. A numbered tag sorts above a branch pseudo-version, so a correct branch bump often reads as a downgrade. Either direction is fine -- the embedded date, not the direction, tells you whether you got your code. |
| `@latest` moved `v0.0.3-0.2026...` -> `v0.0.3` | Correct. `v0.0.3-0.2026...` is a *prerelease of* `v0.0.3`, so the plain release is newer. |
| `go list -m -versions` shows only `v0.0.1 ... v0.0.100` | Tags only. Says nothing about branches. |
| GitHub code search returns 0 results | GitHub doesn't index cs-proto feature branches, and the MCP can't see the repo at all. |
| `not a known dependency` / `not found` from `go list -m` | Module path is wrong. Match go.mod exactly; a *package* path like `.../content-feed/server/public` is not a *module* path. |
| `go mod tidy` put the old numbered tag back after a successful `go get @<branch>` | Usually tidy dropped the require line because nothing imports the module yet, then re-derived it from the graph. Add the imports, re-run `go get`. Not a reason for a `replace` -- see "Do not let `go mod tidy` mask the real state". |
| `go get` **refuses**: `requires <mod>@v0.0.45, not <mod>@v0.0.45-0.2026...` | A real dead end, not a misread: a branch module pins that tag in its own go.mod. This is the one case a `replace` may be warranted -- see below. |
| `malformed module path "<<<<<<<": invalid char '<'` | Unresolved merge conflict in go.mod -- see below. On a conflicted go.mod, `go list` may instead emit a mangled `go help` blob that reads like "module not found". |

### `replace` for a cs-proto-gen-go module: last resort, never silent

`go get` is the way in. Reach for a `replace` only after the escape hatches below are genuinely exhausted, and never add one without telling the user.

**The blocker that justifies it.** A branch build of module A pins module B at a *tag* in its own go.mod (the CI does not rewrite it -- see "Multi-branch and transitive gotchas" below). You need B's branch build, whose pseudo-version `v0.0.45-0.2026...` is a semver *prerelease of* `v0.0.45` and so sorts strictly **below** it. `go get` does not silently downgrade here -- it refuses outright:

```
go: .../subscriptions/client@v0.0.7-0.2026... requires .../merchant_commons@v0.0.45,
not .../merchant_commons@v0.0.45-0.20260813072419-9a06182b4757
```

No `require` can express this, because the constraint lives in A's go.mod, not yours. Once you see that error, `go get` cannot get you there.

Cheapest first:

- **Wait for the proto PR to merge, then `@latest`.** Almost always the right call. The pin has to be undone before merge anyway, so it is pure throwaway work.
- **Get A's branch rebuilt on a master that has tagged past B's blocking tag**, so the new build requires a version your branch pseudo-version can outrank. Costs a CI cycle and only works if master has actually moved.
- **If B's branch pseudo-version already outranks every tag in the graph, a plain `require` is enough** -- check before adding a `replace`. `v0.0.7-0.2026...` beats the `v0.0.6` tag cleanly.

**If you do add one:** cover only the module that is actually blocked, say so explicitly in your reply rather than burying it in a code comment, and let the user decide whether to ship it. A `replace` reaching master pins every consumer of the service to an unmerged branch commit, and it survives the proto PR merging, so nothing forces it to be cleaned up.

### Do not let `go mod tidy` mask the real state

`go mod tidy` **removes a require line for a module nothing imports yet**. Bump first, add the imports, then tidy -- tidying in between drops the pin, and the next tidy re-derives the module from the graph at whatever tag MVS computes (observed: an explicit `v0.0.7-0.2026...` reappearing as `v0.0.6`, with `undefined: ListingTierServiceClient` following).

This looks identical to the prerelease-ordering block above but is not it, and does **not** justify a `replace`. Re-run `go get @<branch>` once the imports are in place and confirm with `go list -m`. One real session read this as "tidy discards explicit pins" and added a second, unneeded `replace`.

### Verify the bump landed

`go get @<branch>` succeeds with a **stale** pseudo-version when the CI hasn't pushed the generated code yet: exit 0, `upgraded`, no warning. The date is embedded in the pseudo-version -- `v0.0.67-0.20260610042217-...` is 2026-06-10. **If it predates your push, the CI hasn't finished: wait and re-run `go get`.** Don't go version-hunting.

Then confirm the symbol is actually there:

```bash
go list -m -f '{{.Dir}}' <module>   # then grep that dir for the new symbol
```

`go list -m -f` reports the version the service actually *resolved*, so grepping that directory is the right check -- grepping the mod cache by hand is not, since MVS may have selected a different version than the one you downloaded. If the service compiles, referencing the new symbol from a throwaway `go build` is stronger still.

### go.mod merge conflicts

Conflict markers break *every* go command. Never resolve them by hand-editing version strings:

```bash
git checkout --theirs go.mod   # or --ours; either side, just clear the markers
cd <service repo> && GOPROXY=direct go get github.com/carousell/cs-proto-gen-go/<svc>/<pkg>@<branch>
go mod tidy
```

The `go get` rewrites go.mod and go.sum correctly, which hand-editing does not.

### Multi-branch and transitive gotchas

- **A feature often spans several proto branches** -- one session needed 5 modules across 3 branches. If the build still fails after a verified bump, another proto you depend on is on a different branch.
- **The CI does not bump the *branch module's own* go.mod.** It still pins whatever `commons` / `merchant_commons` release it was generated against. (Your service's go.mod is different -- `go get` there will happily bump those transitively, which is fine.) If a build error says `merchant_commons.SomeNewType` is undefined *inside a branch-version `.pb.go`*, that pin is why: bump that module to the same branch too. That pin is also what makes `go get` refuse a branch pseudo-version outright (`requires ...@v0.0.45, not ...@v0.0.45-0.2026...`) -- see "`replace` for a cs-proto-gen-go module" above for the escape hatches.
- **Check which branch the currently pinned version came from** before editing protos. Pushing to `feat/x` while the service consumes `feat/x-backend` cost one session ~30 min and a wasted CI cycle.

## Making proto changes

Find the local cs-proto / grp-proto checkout; if unsure ask the user, and if it isn't cloned offer to clone it somewhere sensible (not a temp dir). Confirm with the user whether to use the current branch or a new one (offer worktrees -- `superpowers:using-git-worktrees`).

**1. Merge master before you push.** cs-proto master moves fast, and a stale branch fails CI with breaking-change errors in protos you never touched. A CI cycle is ~5-10 min, so this is far cheaper than the failure:

```bash
git fetch origin master
git log --oneline HEAD..origin/master   # any output => merge before pushing
git merge origin/master --no-edit
```

**2. Lint before you push.** The one session that did this was the only one with zero failed CI cycles:

```bash
./lint.sh --service <service-name>      # expect "buf lint passed"
```

`lint.sh` runs `buf lint` only -- it does **not** run `buf breaking` and does **not** check PII annotations, the two most common CI failures. A green lint does not mean CI will pass. Cover the other two locally before pushing: the master merge in step 1 handles `buf breaking`, and `devctl proto validation` below handles PII. Both are seconds; a CI cycle is 5-10 min.

**PII annotations: run the validator, annotate only what it names.** The check flags a field
only when its *name* matches a built-in PII name pattern (`email`, `*name*`, `city`, ...), so
most new string fields need no annotation at all. `devctl` is local and takes ~1s:

```bash
devctl proto validation --file proto/<service> --base_path proto --disableNonErrorLogs
```

Silence = nothing to annotate. Otherwise it prints one line per field needing one; annotate
exactly those fields and no others. Each printed line is a *suggested* fix, and its enum
guess is often wrong -- `created_by`, `account_id`, `country`, and `name` on a non-user
entity are flagged but are normally `NOT_PII`. Decide from what the field holds.

`NOT_PII` silences a flagged field. On an unflagged field it silences nothing, and CI accepts
it without complaint -- so nothing will ever tell you it was unnecessary. Adding it to
`listing_id`, `status`, `warnings`, or any int/bool is always wrong.

Read `references/pii-annotations.md` before annotating: it has the pattern list, the enum
values, the misleading-suggestion cases, and `devctl proto annotate` (which fixes a whole
file without over-annotating).

**3. Push, then watch the CI** (~5-10 min). Run the watcher with `run_in_background: true` and carry on with other work:

```bash
# the script lives in THIS skill's directory, not in the proto repo -- use its absolute path
~/.claude/skills/carousell-proto-ctf/scripts/watch-proto-ci.sh --branch <branch> --service <service>
# --repo carousell/grp-proto for grp-proto
# several services in one run? repeat --service; ONE watcher covers the whole set:
#   ... --branch <branch> --service content-feed --service listing-visualizer --service subscriptions
```

**Watching several services: repeat `--service`.** One watcher, one exit code, one
thing to tear down. `--service` is a substring regex, so `--service content-feed`
also matches `content-feed-gw` (usually what you want; `--service 'content-feed,'`
anchors to the exact service). List every service whose generated Go you need to
consume -- once the matrix expands the script prints `matrix expanded to: ...` naming
every service in the run, so check that line against your list and restart with more
`--service` flags if you missed one.

Run it with the proto checkout as cwd so it can pin the run to your pushed commit, but invoke it by absolute path -- a bare `scripts/watch-proto-ci.sh` resolves against the proto repo and exits 127 `command not found`. It prints one line per job state change (roughly 10-20 lines for a clean run, depending on how many services the matrix expands to), never fetches logs, and exits `0` = generated, `1` = failed, `2` = timed out.

The script needs bash 4+; it exits 3 with an install hint on stock macOS bash 3.2. If you change its verdict logic, run `scripts/testdata/run-tests.sh` -- it replays recorded CI payloads through every branch offline in ~1s.

**Waiting for CI: start the watcher, then stop.** You are notified when it exits. Do not poll.

- **Expect the log to be empty for the first 1-2 minutes** -- CI hasn't registered the push and the job matrix hasn't expanded. An empty log is not a broken script.
- **Do NOT re-read the watcher's output file in a loop.** One session read an unchanged file ~72 times over ~8 minutes (~145 messages, $4.40), five times narrating "I recognize I'm looping" and then reading again. If you are about to re-read it, stop: the notification is the signal.
- **Do NOT set up a second waiting mechanism** (a `Monitor` until-loop *and* a background poll). Pick one, or you have two things to tear down.
- **Do NOT delegate CI-waiting to a subagent.** Watcher subagents burned 10-22 minutes and *misdiagnosed the failure twice* -- once suggesting `PII_NAME` where `NOT_PII` was correct, once blaming "buf breaking on all modified protos" when the cause was a stale master and an unrelated service. Delegate proto work only for the usual reason: the editing is a large, separable chunk.
- **Do NOT hand-roll a `gh run view` poll loop, even when you need several services**
  -- repeat `--service` instead. One session started the watcher for one service,
  discovered mid-run it needed four, and instead of restarting it with the other
  three killed the watcher for a `while true; do gh run view ...; sleep 30; done`,
  then polled `gh run view` by hand another six times on top of it. Needing more
  services is a reason to restart the script with more `--service` flags, never a
  reason to leave it.
- **Do NOT use `gh run watch`.** It reprints the whole job tree every 3s (70KB-708KB observed) and refuses to report on a finished run.
- **Do NOT trust the run-level conclusion** (`gh run list`'s `conclusion`). It aggregates unrelated jobs in both directions: green when every meaningful job merely `skipped`, red when another service in the matrix broke. Only the `generation (..., <service>, ..., server)` and `(..., client)` jobs gate your Go code; the script already filters to these.

**4. If the CI fails**, read `references/diagnosing-ci-failures.md`. Only fetch logs once the script reports a failure, and diagnose the job it names -- siblings marked `cancelled` are collateral and point at the wrong service.

**5. Bump the service's go.mod** per "Getting a proto version into go.mod" above.

## Searching protos on any branch

Read `references/searching-proto-branches.md` -- a clone plus a fresh worktree, which works for master and feature branches alike.

Do NOT use the GitHub MCP/CLI (no access to cs-proto, and it misses feature branches). Do NOT rely on an existing local cs-proto checkout -- it may be stale or on a different branch than you assume, which has silently produced wrong answers.

## Reading a service's current proto contract

To read the exact proto a service imports today (eg. before proposing an API change to it), use the go mod cache rather than a branch checkout -- the service may be pinned to an old version. Prefer `.proto` files over generated `.pb.go`; they sit alongside each other in cs-proto-gen-go and are far more compact.

```bash
go list -m -f '{{.Dir}}' <exact cs-proto-gen-go module from go.mod>
find <path from above> -name '*.proto'
```

`not a known dependency` means the module path is wrong; no output means the dependency isn't downloaded, so run `go mod download`.

## Common mistakes

- Local copies (go mod cache, your own checkouts, other repos) may be stale or incomplete. Don't use the go mod cache to answer "does this service exist in cs-proto" -- no one builds every service locally.
- **A gateway proto and its backing service proto usually have different field numbers**, because the service side adds an `auth_user_container` at field 1 and shifts the rest. Any marshal/unmarshal shortcut between the two (`convertProto`-style) depends on the numbers matching, so it compiles fine and silently mis-maps at runtime. Compare the field numbers on both sides before using one.
- Only trust protos from the canonical sources (cs-proto, grp-proto, cs-proto-gen-go). Ignore stray copies elsewhere on the filesystem -- a service's vendored `pb/`, test fixtures, `integration-tests/.shared-proto/...` -- even if they look canonical.

## Legacy shared-proto

The pre-CTF proto system, being migrated to cs-proto. Protos live at <https://github.com/carousell/shared-proto>.

- Generated `.pb.go` files are committed to each backend service's repo, typically in `pb/`.
- Run `./generate_protobufs.sh` in a backend service to regenerate them; `protogen.yaml` controls which services it generates. When migrating a service to cs-proto, delete it from `protogen.yaml`.
