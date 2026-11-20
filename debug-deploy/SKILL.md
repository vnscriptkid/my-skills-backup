---
name: debug-deploy
description: "Debug a failed Carousell service deployment. Fetches GitHub Actions logs, cross-references with local code and recent commits, checks Kubernetes pod status for deploy failures, and suggests fixes. Usage: /debug-deploy <free-form message describing the failure>"
argument-hint: "<service/branch/run-url or description of what failed>"
allowed-tools: Read, Bash(git rev-parse *), Bash(git log *), Bash(git diff *), Bash(gh run *), Bash(kubectl get *), Bash(kubectl logs *), Bash(kubectl describe *), Bash(gcloud container clusters get-credentials *)
---

# debug-deploy: Diagnose Failed Deployments

You are debugging a failed Carousell service deployment. Your job is to find the root cause and suggest a fix through a phased investigation.

---

## Step 0: Parse Input & Resolve Context

The user provides a free-form message. Extract whatever is available:

- **Run URL**: e.g. `https://github.com/carousell/<service>/actions/runs/<id>` — extract service name and run ID directly
- **Service name**: explicit mention, or infer from primary working directory (last segment of repo path)
- **Branch**: explicit mention, or run `git rev-parse --abbrev-ref HEAD`
- **Environment**: staging (default), or a feature env name if mentioned

**Resolution logic (in priority order):**

1. If a run URL is provided → extract service + run ID, skip to Step 1
2. If service + branch provided → find latest failed run via `gh run list`
3. If only service provided → find latest failed run across all branches
4. If nothing usable → infer service from cwd, branch from git, find latest failed run
5. If still ambiguous → ask the user

**Finding a failed run** (when no run URL given):

```bash
gh run list --repo carousell/<service> --workflow deploy.yml --branch <branch> --status failure --limit 5 --json databaseId,status,createdAt,headBranch,event
```

If no `--branch` filter, omit it to search across all branches. Pick the most recent `workflow_dispatch` run.

If no failed runs found, also check `--status cancelled` and runs that are currently in progress. If still nothing, tell the user no recent failed deployment was found and ask for more details.

**Confirm with the user before proceeding:**

```
Found failed run #<RUN_ID> for <service>/<branch> (<environment>)
Run URL: https://github.com/carousell/<service>/actions/runs/<RUN_ID>
Investigating...
```

Store: `SERVICE`, `BRANCH`, `RUN_ID`, `ENV_TYPE` (staging | feature), `FEATURE_ENV_NAME` (if applicable).

---

## Phase 1: Error Extraction & Summary

**Fetch run details and failed logs in parallel:**

```bash
gh run view <RUN_ID> --repo carousell/<SERVICE> --json jobs --jq '.jobs[] | {name, conclusion, startedAt, completedAt}'
```

```bash
gh run view <RUN_ID> --repo carousell/<SERVICE> --log-failed
```

**Parse the logs to identify:**

1. **Which job failed**: init (ci-deploy-init), build (docker-build), or deploy (trigger-system-deploy)
2. **Which step within the job failed**
3. **The error message**: extract the relevant error lines (NOT the full log dump)

**Classify the failure:**

| Category | Examples |
|---|---|
| `branch-not-found` | ref not found, branch doesn't exist |
| `permission-error` | 403, insufficient permissions |
| `compilation-error` | Go build errors with file:line references |
| `dependency-error` | go get failures, module not found, version conflicts |
| `docker-build-error` | Dockerfile issues, missing files, build arg problems |
| `image-pull-error` | image not found, registry auth failure |
| `helm-error` | chart issues, values errors, template rendering |
| `rollout-timeout` | deadline exceeded waiting for deployment |
| `pod-crash` | CrashLoopBackOff, OOMKilled, runtime panics |
| `unknown` | doesn't match known patterns |

**Present the summary:**

```
Phase 1: Error Summary

  init    [checkmark or x or skipped]
  build   [checkmark or x or skipped]
  deploy  [checkmark or x or skipped]

Failed step: "<step_name>"
Category: <category>

Error:
  <relevant error lines, 1-10 lines max>
```

**Early exit check:**
- If category is `branch-not-found`, `permission-error`, or another init failure where the fix is obvious → present the fix suggestion and STOP. No need for further phases.
- Otherwise → proceed to Phase 2.

---

## Phase 2: Local Code & Commit Analysis

**Cross-reference the error with local source code:**

- **Compilation errors**: Read the exact files and lines referenced in the error output. Show the surrounding context.
- **Dependency errors**: Read `go.mod` and check for the problematic module. Run `go list -m <module>` if needed.
- **Docker build errors**: Read the `Dockerfile` and any files referenced in the failing step.
- **Deploy/runtime errors**: Read config files, helm values, or entrypoint code as relevant.

**Analyze recent branch changes:**

```bash
git log master..<BRANCH> --oneline --stat
```

```bash
git diff master...<BRANCH> -- <files_related_to_error>
```

Focus the diff on files that are relevant to the error — don't dump the entire branch diff.

**Present findings:**

```
Phase 2: Code Analysis

Changed files on branch (vs master):
  <file>  (+N, -M)
  <file>  (+N, -M)

Error context:
  <explanation of what the code shows in relation to the error>

Recent commits:
  <hash>  <message>
  <hash>  <message>
```

**Early exit check:**
- If the root cause is clear from code analysis (typo, missing export, wrong signature, bad config) → go to Phase 4 (Synthesis).
- If the failed job is **deploy** (not build) → proceed to Phase 3.
- Otherwise → go to Phase 4.

---

## Phase 3: Kubernetes Investigation

**Only run this phase when the deploy step failed.**

**Connect to the correct cluster:**

| Environment | Command | Namespace |
|---|---|---|
| Staging | `gcloud container clusters get-credentials staging-main-k127 --zone asia-east1-c --project carousell-staging` | `<SERVICE>` (the system name) |
| Feature env | `gcloud container clusters get-credentials staging-feature-k127 --zone asia-east1-c --project carousell-staging` | `<FEATURE_ENV_NAME>` |

**Investigation steps:**

1. **Get pod status:**
   ```bash
   kubectl get pods -n <NAMESPACE> | grep <SERVICE>
   ```

2. **If pods are in CrashLoopBackOff or Error:**
   ```bash
   kubectl logs <POD_NAME> -n <NAMESPACE> --tail=100
   ```
   If the pod has restarted, also check previous instance:
   ```bash
   kubectl logs <POD_NAME> -n <NAMESPACE> --previous --tail=100
   ```

3. **If pods are Pending or ImagePullBackOff:**
   ```bash
   kubectl describe pod <POD_NAME> -n <NAMESPACE>
   ```

4. **Check recent events:**
   ```bash
   kubectl get events -n <NAMESPACE> --sort-by=.lastTimestamp | tail -20
   ```

**Present findings:**

```
Phase 3: Kubernetes Status

Cluster: <cluster>
Namespace: <namespace>

Pod status:
  <pod_name>   <status>  (<restart count> restarts)

<If CrashLoopBackOff — last log output>
<If Pending — describe output showing why>
<If ImagePullBackOff — image details>

Recent events:
  <relevant events>
```

---

## Phase 4: Synthesis & Fix Suggestion

Combine findings from all phases into a final diagnosis.

**Assess confidence:**

| Level | Criteria |
|---|---|
| **High** | Single clear error with obvious fix (compilation error, name mismatch, missing file, wrong image tag) |
| **Medium** | Likely root cause but multiple factors or some ambiguity (runtime panic, config issue, dependency conflict) |
| **Low** | Ambiguous failure, multiple possible causes (intermittent timeout, flaky infra, race condition) |

**Present the diagnosis:**

```
Diagnosis

Root cause: <clear explanation of what went wrong and why>

Suggested fix:
  <specific actionable steps or code changes>

Confidence: <High | Medium | Low> — <brief justification>
```

**For Medium/Low confidence**, present multiple hypotheses ranked by likelihood:

```
Diagnosis

Most likely cause (Medium confidence):
  <hypothesis 1 with explanation>

Alternative causes:
  <hypothesis 2>
  <hypothesis 3>

Suggested next steps:
  1. <most promising action>
  2. <fallback action>
```

**After presenting the diagnosis:**
- For High confidence fixes that are local code changes → ask: "Want me to apply this fix?"
- For Medium/Low confidence → ask: "Want me to investigate further, or would you like to try one of these fixes?"
- NEVER auto-apply fixes without asking.

---

## Important Notes

- Do NOT dump raw logs. Always extract and summarize the actionable information.
- Keep error excerpts to 1-10 lines of the most relevant output.
- When reading local files, show only the relevant sections around the error, not entire files.
- If `gh` commands fail (e.g., auth issues), tell the user and suggest `gh auth login`.
- If `kubectl` commands fail, tell the user and suggest the appropriate `gcloud` auth command.
- If the failure is clearly an infrastructure/platform issue (not code), say so — don't force a code-level diagnosis.
- Respect phase early-exit logic — don't run unnecessary phases when the answer is already clear.
