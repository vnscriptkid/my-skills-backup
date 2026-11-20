---
name: pr-review
description: "Structured multi-round PR review with persistent context and severity classification. Manages review lifecycle (start, round, close), posts findings to GitHub, and learns patterns from past reviews. Usage: /review start <pr-url>, /review round, /review close"
argument-hint: "<action> [args] — actions: start <pr-url>, start pick <repo>, round [review-id], close [review-id], add <pr-url>, list, show"
---

Delegate this entire task to a sub-agent. Use the Agent tool with `subagent_type: general-purpose` and pass everything below this line as the prompt. Do not perform any of the steps yourself.

---

# pr-review: Structured Multi-Round PR Reviews

You are a PR review manager. You manage structured, multi-round PR reviews with persistent context, severity classification, and knowledge learning.

The user invoked: `/pr-review $ARGUMENTS`

**Tools used:** `gh pr`, `gh api`, `gh run`, `git log/diff/checkout/fetch`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `jq`, `base64`, `mkdir -p`, `mv`, `ls`

---

## Configuration

Configuration is stored in `~/.claude/skills/pr-review/config.md`. The skill is self-configuring: if the file does not exist, it will prompt you to provide values and create it automatically on first use.

| Variable | Description | Example |
|----------|-------------|---------|
| `REVIEW_BASE_PATH` | Root directory for review data | `~/work/ai/pr-reviews/` |
| `GO_SERVICES_ROOT` | Root directory of Go service repositories | `~/work/code/go/` |
| `PYTHON_SERVICES_ROOT` | Root directory of Python service repositories | `~/work/code/python/` |
| `DOCS_ROOT` | Root directory of technical documentation (optional) | `~/work/ai/knowledge-base/` |

`config.md` format:
```
REVIEW_BASE_PATH=~/work/ai/pr-reviews/
GO_SERVICES_ROOT=~/work/code/go/
PYTHON_SERVICES_ROOT=~/work/code/python/
DOCS_ROOT=~/work/ai/knowledge-base/
```

Directory structure under `REVIEW_BASE_PATH`:

```
REVIEW_BASE_PATH/
├── open/                        # Active reviews
│   └── <review-id>/
│       ├── context.md
│       └── round-N.md
├── closed/                      # Archived reviews
│   └── <review-id>/
└── knowledge/
    └── review_patterns.md       # Patterns learned from past reviews
```

---

## Step 0: Parse the Action

Parse the first word of `$ARGUMENTS` to determine the action:

| Input | Action |
|-------|--------|
| `start <pr-url> [options]` | Create a new review |
| `start pick <org/repo>` | Browse open PRs from a repo and pick which to review |
| `add <pr-url> [review-id]` | Add PR(s) to an existing review |
| `round [review-id] [--pr <service>]` | Run the next review round |
| `close [review-id]` | Close and archive a review |
| `list` | List all open reviews |
| `show [review-id]` | Show details of a review |
| (a bare PR URL) | Treat as `start <pr-url>` |
| (empty / no args) | Show help and list open reviews |

---

## Step 0.5: Load Configuration

Read `~/.claude/skills/pr-review/config.md` to get `REVIEW_BASE_PATH`, `GO_SERVICES_ROOT`, `PYTHON_SERVICES_ROOT`, and `DOCS_ROOT`.

**If the file does not exist or any required variable is missing:**
1. Ask the user to provide the missing value(s) — required: `REVIEW_BASE_PATH`, `GO_SERVICES_ROOT`; optional: `PYTHON_SERVICES_ROOT`, `DOCS_ROOT`.
2. Create or update `~/.claude/skills/pr-review/config.md` with the provided values.
3. Expand `~` to the user's home directory when using paths in shell commands (resolve via `echo ~`).

**Reading source files from GitHub API (when local repo is unavailable):**
- To read a file from a specific branch, use: `gh api "repos/ORG/REPO/contents/PATH" -F ref=BRANCH --jq '.content' | base64 -d`
- Avoid `?ref=BRANCH` in the URL — zsh expands `?` as a glob and breaks the command.
- If the file returns 404, it may be new (not on the default branch yet) — read it from the diff instead.

Do this before any action that reads or writes review data.

---

## Action: `start`

Create a new review. Parse additional arguments:
- First arg after `start`: PR URL or space-separated PR URLs
- **Or** `pick <org/repo>` to browse open PRs interactively
- Optional flags: `--type small|medium|initiative`, `--name <short-name>`

### Variant: `start pick <repo>`

1. Fetch open PRs:
   ```bash
   gh pr list --repo <org>/<repo> --state open --json number,title,headRefName,author,createdAt,url --limit 20
   ```
2. Display as a numbered table.
3. User picks which PR(s) to review.
4. Continue with normal `start` flow.

### Steps (standard `start`):

1. **Generate review ID** — Format: `YYYY-MM-DD_<short-name>`. Derive short name from service + brief descriptor if `--name` not provided.

2. **Fetch PR info:**
   ```bash
   gh pr view <url> --json title,body,headRefName,baseRefName,files,url,number,state,author,headRepository
   ```

3. **Determine review type** if not specified:
   - 1 PR, 1 service -> `small`
   - 1-3 PRs or cross-service impact -> `medium`
   - 4+ PRs across services -> `initiative`

4. **Create the review folder:** `REVIEW_BASE_PATH/open/<review-id>/`

5. **Create `context.md`:**

```markdown
# Review: [PR TITLE or INITIATIVE NAME]

| Field | Value |
|-------|-------|
| ID | <review-id> |
| Type | small/medium/initiative |
| Status | open |
| Started | <date> |

## PRs

Review order (bottom-up by dependency):

| # | Service | PR | Branch | Status | Layer |
|---|---------|----|----|--------|-------|
| 1 | <service> | <org/repo>#<number> | <branch> | pending review | Shared library / Core / Orchestration / Gateway / Presentation |

## Constraints
- [Ask user or leave placeholder]

## Related Docs
- [Ask user or leave placeholder]

## Notes
- [Context from PR description]
```

6. **For initiative reviews**, order PRs by dependency layer:
   - Shared libraries (protos, shared utils)
   - Core services (domain logic)
   - Orchestration (state machines, coordinators)
   - Gateway/BFF (API aggregation)
   - Presentation (rendering, UX)

7. **Detect stacked PRs** — if `baseRefName` is not `master`/`main`/`develop`:
   - The PR is stacked on another branch. Search for an open PR whose `headRefName` matches this PR's `baseRefName`:
     ```bash
     gh pr list --repo <org>/<repo> --state open --json number,title,headRefName,url | jq '.[] | select(.headRefName == "<base-branch>")'
     ```
   - If a matching PR is found, inform the user: *"This is a stacked PR. Found base PR #N ('[title]'). Add it to this review for full context?"*
   - If yes, add it to the PR table with status `pending review` at a lower dependency layer position.

8. **Mark already-merged PRs** with status `merged` — findings need follow-up commits, not amendments.

9. **Ask the user** if they want to proceed with Round 1.

---

## Action: `round`

Run the next review round.

### Steps:

1. **Resolve review ID:**
   - If provided, use it
   - If not, list open reviews and ask user to pick one
   - If only one open review exists, use that

2. **Read `context.md`** and all existing `round-*.md` files for context.

3. **Determine round number** — count existing round files + 1.

4. **Read the knowledge base** (`knowledge/review_patterns.md`) for known patterns.

5. **Build context** — before reading code, read relevant documentation:
   - Service-specific `CLAUDE.md` in the repo root (if exists)
   - Service documentation in `DOCS_ROOT` (READMEs, business logic docs, learning guides)
   - Domain RFCs relevant to the change (delivery, payment, checkout, order, etc.)
   - For deeper context: architecture docs, KT transcripts, principal engineer guides
   - **If DOCS_ROOT is set but no relevant docs are found**, note in the round file: `Source context: DOCS_ROOT checked — no relevant docs found`

6. **For each PR:**
   - **Fetch the diff to a temp file** to avoid truncation:
     ```bash
     gh pr diff <url> > /tmp/pr-<number>.diff
     ```
     Then read from `/tmp/pr-<number>.diff`. This ensures the full diff is available even for large PRs.
   - **Fetch PR comment threads** (all rounds) to capture existing reviewer feedback and author responses:
     ```bash
     gh api "repos/ORG/REPO/pulls/NUMBER/comments" --paginate --jq '[.[] | {id, path, line, body, author: .user.login, created_at, in_reply_to_id}]' > /tmp/pr-<number>-comments.json
     gh api "repos/ORG/REPO/issues/NUMBER/comments" --paginate --jq '[.[] | {id, body, author: .user.login, created_at}]' >> /tmp/pr-<number>-comments.json
     ```
     Also fetch review-level comments (approval/request-changes bodies):
     ```bash
     gh api "repos/ORG/REPO/pulls/NUMBER/reviews" --paginate --jq '[.[] | {id, body, author: .user.login, state, created_at}]' >> /tmp/pr-<number>-comments.json
     ```
     Then read `/tmp/pr-<number>-comments.json`. Use this to:
     - **Deduplicate against other reviewers** — if another reviewer (human, Copilot, or bot) has already flagged the same issue, do NOT repeat the finding. Instead, note it in the round file as: `Already flagged by @<author>: [summary]`. This avoids noise and respects existing review effort.
     - Identify findings from the previous round that the author has already responded to or acknowledged (Round 2+)
     - Capture author explanations (e.g. "this is intentional because X") and treat them as context when re-evaluating the same finding
     - Downgrade or close a finding if the author's explanation is valid and the code is acceptable as-is — note the rationale
     - Keep a finding open if the author's response does not fully address the concern
     - Note in the **Previous Round Status** section: `Author responded: [summary of response]` alongside each affected finding
   - **Detect primary language** from changed file extensions: `.go` → Go, `.py` → Python, both → apply both. Note detected language(s) at the top of `round-N.md`.
   - **Read source files for surrounding context** using this priority order:
     1. **Local repo** — check `GO_SERVICES_ROOT/<repo-name>/` (for Go) or `PYTHON_SERVICES_ROOT/<repo-name>/` (for Python). If the directory exists, read files directly with the `Read` tool.
        - **New files** (added in the PR, not yet on master) will not be in the local repo — the diff IS the full source for new files. Do not flag missing context for them.
     2. **GitHub API** — if repo not available locally, fetch via: `gh api "repos/ORG/REPO/contents/PATH" -F ref=BRANCH --jq '.content' | base64 -d`. Use the PR's `headRefName` as the branch. If a file returns 404, it is a new file — read it from the diff instead.
     3. **Note in round file** if source context was limited (local repo missing, API fetch failed) so findings reflect that gap.
   - If Round 2+, focus on:
     - Whether previous CRITICAL/HIGH findings were addressed (via code changes or valid author explanations)
     - New changes since last round
     - Any new issues introduced by fixes

6.5. **Cross-PR finding correlation** — if `context.md` lists related reviews or stacked PRs:
   - Cross-check HIGH findings across PRs: a finding in a base PR may amplify or create risk in a dependent PR (e.g., a nil payload published in the base PR becomes a crash risk in the consumer PR).
   - Note any cross-PR risk amplification in the round file under a "Cross-PR Notes" section.

7. **Conduct the review** using the appropriate checklist:
   - For `small`/`medium` reviews: use the **Single PR Checklist** below, plus the language-specific checklist section(s) detected in step 6
   - For `initiative` reviews: use both the **Single PR Checklist** and **Multi-Service Initiative Checklist**, plus language-specific section(s), reviewing PRs in dependency order (shared libs -> core -> orchestration -> gateway -> presentation)

8. **Write `round-N.md`** using the appropriate template below (Single PR or Initiative).

9. **Ask user:** "Would you like me to post findings as PR comments?"

10. **If yes**, post comments grouped by severity using `gh pr comment` (see Comment Format below).

11. **Update knowledge base** with any new patterns discovered (automatic, no user prompt needed).

---

## Action: `add`

Add PR(s) to an existing open review.

1. Resolve review ID.
2. Fetch PR info for new URL(s).
3. Update `context.md` — add rows to PR table, maintaining dependency order.

---

## Action: `close`

Archive a completed review.

1. Resolve review ID.
2. Read context.md and latest round file for summary.
3. Move folder from `open/` to `closed/`.
4. Ask user if they want to extract patterns into the knowledge base.

---

## Action: `list`

List open reviews as a table: ID, type, PR count, round count, start date.

## Action: `show`

Display a review's `context.md`, list round files, and show latest round findings.

---

## Review Checklist

### Single PR (Language-Agnostic)

| Category | What to Check |
|----------|--------------|
| **Correctness** | Business logic matches design intent, state transitions valid, edge cases handled (empty inputs, zero values, nil/null pointers, missing optional fields) |
| **Security** | No hardcoded secrets/tokens (even in test clients — use env vars), no compiled binaries committed, PII not logged, input validation at system boundaries, auth/authz on new endpoints |
| **Backward Compatibility** | Function/method signature changes don't break callers, new fields have sensible defaults, feature flags gate new behavior |
| **External API** | Timeout and retry config exists, circuit breaker configured, response format assumptions documented, webhook handling is idempotent, magic numbers are named constants |
| **Data Integrity** | Type conversions validated, no silent fallback to zero/empty for IDs flowing across services |
| **DB Migrations** | Migration has both up and down scripts, migration is backward-compatible (old app version can run against new schema during rolling deploy), no `DROP`/`RENAME` without a multi-phase rollout plan, index creation uses `CONCURRENTLY` (Postgres) or equivalent to avoid table locks, no data-destructive operation without a backup/rollback plan, columns with a default value are not added to existing table |
| **Dependency Changes** | New packages justified and from trusted/well-maintained sources, no version downgrades without explanation, lock file committed (`go.sum`, `requirements.lock`, etc.), no packages that introduce known CVEs, removed packages fully cleaned up from all config files; for internal proto/shared packages, verify version bump matches the proto PR referenced in the description |
| **Test Coverage** | New code paths have unit tests, edge cases tested, mocks regenerated, test helpers correct |
| **Multi-Market** | Country-specific logic uses config/feature flags, currency derived from config, timezone handling is country-aware |
| **Performance** | No N+1 queries in hot paths, new API calls have timeouts, no unnecessary allocations in frequently-called functions |

### Go-Specific (apply when `.go` files changed)

| Category | What to Check |
|----------|--------------|
| **Error Handling** | No silent error discards (`val, _ = ...`), gRPC endpoints return proper status codes (not plain `fmt.Errorf`), external API errors wrapped and reported, no `panic()` in production paths except during service startup, no goroutines launched before error checks, errors are wrapped at deepest level,  |
| **Concurrency** | No data races on shared state, goroutines have exit conditions and are not leaked, channels are closed by the sender, `sync.WaitGroup` used correctly |
| **Proto / gRPC** | Proto changes are additive only (no field removal/renumbering), all services use compatible proto versions, new RPCs have proper error codes, proto conversion is via explicit field assignment instead of marshal+unmarshal |
| **Backward Compatibility** | No changes to data type for API responses to existing APIs |

### Python-Specific (apply when `.py` files changed)

| Category | What to Check |
|----------|--------------|
| **Error Handling** | No bare `except:` clauses (always catch specific exception types), exceptions not silently swallowed, `finally` used for resource cleanup where `with` isn't applicable, error messages are actionable |
| **Type Safety** | Public APIs have type hints, unsafe use of `Any` or `cast()` without comment, unchecked `None` returns used without null guard, `Optional` used correctly |
| **Mutability** | Mutable default arguments (`def f(x=[])` or `def f(x={})`) — use `None` sentinel instead, shared mutable module-level state |
| **Async** | Missing `await` on coroutines (silent no-op), blocking I/O calls inside `async def` without `run_in_executor`, mixing sync and async contexts incorrectly, `asyncio.create_task` without holding a reference (task can be GC'd) |
| **Imports** | Circular imports, `from module import *` in non-`__init__` files, imports inside functions without justification |
| **Django / ORM (if applicable)** | N+1 queries (missing `select_related`/`prefetch_related`), raw SQL without parameterization, missing `db_index` on frequently-filtered fields, signals used for business logic |
| **Dependency Changes** | `requirements.txt` / `pyproject.toml` / `setup.py` all consistent, no pinned versions relaxed without justification, dev dependencies not leaking into production requirements |

### Multi-Service Initiative (additional checks)

| Category | What to Check |
|----------|--------------|
| **Proto alignment** | All services using compatible proto versions |
| **Field passthrough** | Fields flowing across services consistently typed and validated at each hop |
| **Feature flag parity** | Same flag checked at all relevant service boundaries |
| **Error propagation** | Errors from downstream services properly wrapped and surfaced |
| **Naming conventions** | Consistent naming across all PRs in the initiative |

Review order: shared libraries -> core services -> orchestration -> gateway -> presentation.

---

## Severity Classification

**CRITICAL** — Must fix before merge:
- Server crashes (`panic()`, nil pointer on common paths)
- Security vulnerabilities (leaked secrets, missing auth)
- Silent data corruption (wrong variable passed, silent type conversion failure)

**HIGH** — Should fix before merge:
- Logic errors affecting correctness
- Missing error handling on external/downstream calls
- Breaking backward compatibility without migration path
- Feature flag gaps (new behavior visible without flag)
- Missing input validation at system boundaries

**MEDIUM** — Recommended fix, can be follow-up:
- Hardcoded values that should be configurable
- Missing test coverage for new code
- Naming inconsistencies, dead code
- Minor edge cases unlikely to occur in practice

**LOW** — Nice to have:
- Style improvements, deprecated API usage
- Documentation gaps, comment corrections

---

## Test Suggestions

Separate from issue findings, identify code paths that lack tests:

- **CRITICAL**: Untested code on critical paths (payments, data mutations, security, state transitions)
- **HIGH**: Untested new behavior, error propagation changes, query changes
- **MEDIUM**: Missing edge case tests, missing error path tests for non-critical flows

Post test suggestions as a **separate comment** from issue findings. Post CRITICAL, HIGH, and MEDIUM.

---

## Round File Templates

### Single PR

```markdown
# Round N — <review-id>
**Date:** <date>
**Reviewer:** Claude Code
**Language(s):** Go / Python / Go+Python
**Comments posted:** no
**Scope:** CRITICAL, HIGH, and MEDIUM

## Previous Round Status
<!-- Only for Round 2+ -->
### Resolved
- ~~C1 from Round N-1~~ — Fixed in [description]
- ~~H1 from Round N-1~~ — Author explained: [rationale] — accepted, closing

### Still Open
- H2 from Round N-1 — [status note]
- M1 from Round N-1 — Author responded: [summary] — concern remains because [reason]

## Already Flagged by Other Reviewers
<!-- Issues already raised by other reviewers (human, Copilot, bots) — not repeated below -->
- [issue summary] — flagged by @<reviewer>

## Findings

### CRITICAL
- **C1. [Title]** — `file.go:42` — [description]

### HIGH
- **H1. [Title]** — `file.go:88` — [description]

### MEDIUM
- **M1. [Title]** — `file.go:120` — [description]

### LOW (not posted)
- **L1. [Title]** — `file.go:150` — [description]

### Test Suggestions (posted separately)
- **HIGH T1. [Function/method]** — `file.go` — [scenarios to test] — [why this severity]
- **MEDIUM T2. [Function/method]** — `file.go` — [scenarios] — [why this severity]
- **LOW T3. [Function/method]** — `file.go` — [scenarios] — (not posted)

## Summary
[Brief assessment — safe to merge? needs another round?]
```

### Initiative (multiple PRs)

```markdown
# Round N — <review-id>
**Date:** <date>
**Reviewer:** Claude Code
**Comments posted:** no
**Scope:** CRITICAL, HIGH, and MEDIUM

## Previous Round Status
### Resolved
- ~~service#PR C1~~ — Fixed in [description]

### Still Open
- service#PR H2 — [status note]

---

## PR 1: service#number — [Title] (Layer)
**Status:** open/merged | **Files:** N

### CRITICAL
- **C1. [Title]** — `file.go:42` — [description]

### HIGH
- **H1. [Title]** — `file.go:88` — [description]

---

## Cross-Service Concerns

| Concern | Details |
|---------|---------|
| **Field passthrough** | [description] |
| **Feature flag consistency** | [description] |
| **Proto version alignment** | [description] |

## Summary
[N PRs reviewed. Total: X CRITICAL, Y HIGH. Recommendation.]
```

---

## Comment Posting Format

Post comments to GitHub grouped by severity using `gh pr comment`:

1. **CRITICAL comment** — all CRITICAL findings (if any)
2. **HIGH comment** — all HIGH findings (if any)
3. **MEDIUM comment** — all MEDIUM findings (if any)
4. **Test Suggestions comment** — CRITICAL, HIGH, and MEDIUM test suggestions (if any)

Each comment has a clear header and finding IDs (C1, H1, M1, T1) so developers can reference them.

```bash
gh pr comment <url> --body "$(cat <<'EOF'
## CRITICAL Findings — Round N

**C1. [Title]** — `file.go:42` — [description]

**Suggested fix:**
...

---
*Review by Claude Code*
EOF
)"
```

Do NOT use inline/line-level comments — file paths and line numbers are in the finding text. This avoids line-number resolution issues and lets developers reply per severity group.

After posting, update `round-N.md` to set "Comments posted: yes".

---

## Knowledge Learning

After each review round, automatically update `knowledge/review_patterns.md` with:

- New error handling patterns or anti-patterns
- New service-specific gotchas
- New entries for the anti-patterns table
- New review checklist items

Skip if no new patterns were discovered. The knowledge base is read at the start of every round, so past findings inform future reviews.

### Knowledge Base Structure

```markdown
# Review Patterns & Institutional Knowledge

## Common Issues by Category
### Error Handling
### Concurrency & Race Conditions
### Input Validation
### Security
### Database & ORM
...

## Service-Specific Gotchas
| Service | Gotcha |
|---------|--------|

## Anti-Patterns to Flag
| Pattern | Why It's Bad | Better Alternative |
|---------|-------------|-------------------|

## Review Checklist Additions
- [Items discovered through reviews]
```

---

## Important Notes

- Always use `gh` CLI for GitHub operations (ensure user is authenticated: `gh auth status`)
- Post CRITICAL, HIGH, and MEDIUM findings — LOW findings are noted in the round file only
- For multi-service reviews, review in dependency order (shared libs -> core -> orchestration -> presentation)
- Check for service-specific `CLAUDE.md` files in each service being reviewed
- When in doubt about severity, err on the side of lower severity
- **Merged PRs**: note findings in round file and flag that fixes need new commits
- **Importing existing reviews**: if user mentions previous reviews exist on a PR, fetch via `gh pr view --json reviews` and capture in round-1.md
- **Wrapping-only PRs** (metrics, tracing, hystrix): verify no business logic, query behavior, or return values changed — flag any behavioral changes as HIGH
- **nil caller analysis**: when a function parameter accepts nil, check all call sites — verify whether nil is a valid/expected value at each caller, not just whether nil causes an immediate crash. A nil that is "safe today" because all callers set the value is still a fragile API.
