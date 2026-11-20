---
name: deploy
description: "Trigger a staging or feature environment deployment for any Carousell service from local. Watches all 3 stages (init, build, deploy), and on failure fetches logs and provides root cause analysis. Usage: /deploy [branch]"
argument-hint: "[branch]"
allowed-tools: Read, Bash(git rev-parse *), Bash(gh api user *), Bash(gh workflow run deploy.yml *), Bash(gh run *)
---

# deploy: Trigger Staging/Feature Deployment from Local

You are deploying a Carousell service to staging or a feature environment. Production deployments are **strictly forbidden**.

---

## Step 0: Resolve inputs

**Service name:**
- Determine from the primary working directory name: the last segment of the repo path
- e.g., `/Users/x/code/go/src/github.com/carousell/semantica` → `semantica`
- The service repo is always `carousell/<service_name>`

**Branch:**
- If `$ARGUMENTS` is provided, use it as the branch name
- Otherwise: run `git rev-parse --abbrev-ref HEAD` in the service repo to get the current branch

**Release engineer:**
- Auto-detect via: `gh api user -q .login`

**BU:**
- Always `cs`

**Environment:**
- Ask the user: "Deploy to **staging** or a **feature environment**?"
- If feature environment: the user MUST provide the `feature_env_name` explicitly
- **Exception**: if the user has explicitly asked the agent to "deploy and test" autonomously, the agent may generate a feature env name like `fe-<branch-name-truncated-to-20-chars>`
- NEVER guess or assume a feature env name in normal usage — always ask

---

## Step 1: Safety checks

**HARD GATE — Production block:**
If `env_name` is `prod` or `infra-prod`, REFUSE and EXIT immediately:
> "Production deployments from local are not allowed. Use the standard production pipeline via cs-cd."

**Branch warning:**
If deploying from `master` or `main` to a feature environment, warn the user:
> "You're on `master` — deploying to a feature env from master is unusual. Continue? (y/n)"

**Confirmation:**
Before triggering, show a summary and ask for confirmation:
```
Deploying:
  Service:     <service_name>
  Branch:      <branch>
  Environment: <staging | feature: feature_env_name>
  Engineer:    <github_username>

Proceed? (y/n)
```

---

## Step 2: Trigger the deployment

Trigger the `deploy.yml` workflow on the service repo:

```bash
gh workflow run deploy.yml \
  --repo carousell/<service_name> \
  --ref <branch> \
  -f bu=cs \
  -f env_name=staging \
  -f system_name=<service_name> \
  -f release_engineer=<github_username>
```

If deploying to a feature environment, add:
```bash
  -f feature_env_name=<feature_env_name>
```

Note: `env_name` is always `staging` for feature env deployments (feature envs run on staging infra).

---

## Step 3: Find the workflow run

Wait 5 seconds for the run to register, then find it:

```bash
gh run list --repo carousell/<service_name> --workflow deploy.yml --branch <branch> --limit 5 --json databaseId,status,createdAt,event
```

Pick the most recent `workflow_dispatch` run. If none found, wait 5 more seconds and retry once.

Store the `RUN_ID` and print the URL:
```
Deployment triggered: https://github.com/carousell/<service_name>/actions/runs/<RUN_ID>
```

---

## Step 4: Watch the deployment

Watch all three jobs in real-time:

```bash
gh run watch <RUN_ID> --repo carousell/<service_name> --exit-status
```

This will show progress of:
1. **init** (ci-deploy-init) — resolves env, tags, slack notifications
2. **build** (docker-build) — builds the Docker image
3. **deploy** (trigger-system-deploy) — deploys to the target environment

---

## Step 5: Report results

After the run completes, get the full job breakdown:

```bash
gh run view <RUN_ID> --repo carousell/<service_name> --json jobs --jq '.jobs[] | {name, conclusion, startedAt, completedAt}'
```

### On success:

```
Deployment completed successfully

  init    ✓
  build   ✓
  deploy  ✓

Run: https://github.com/carousell/<service_name>/actions/runs/<RUN_ID>
```

Then ask: **"Want me to test the deployed endpoints? (`/test-deploy`)"**

If the user says yes, invoke the `/test-deploy` skill, passing along the resolved service name, branch, and environment context.

### On failure:

Proceed to Step 6.

---

## Step 6: Failure analysis

Fetch the failed job logs:

```bash
gh run view <RUN_ID> --repo carousell/<service_name> --log-failed
```

**Parse the logs to identify:**
1. **Which job failed**: init, build, or deploy
2. **Which step within the job failed**: e.g., "Go build", "Docker push", "Helm deploy"
3. **The error message**: extract the relevant error lines (not the full log dump)

**Present a summarized diagnosis:**

```
Deployment failed at: <job_name>

  init    ✓ | ✗
  build   ✓ | ✗ | ⊘ (skipped)
  deploy  ✓ | ✗ | ⊘ (skipped)

Failed step: "<step_name>"

Root cause:
  <Extracted error message, 1-5 lines of relevant context>
  <Brief interpretation of what went wrong>

Full logs: https://github.com/carousell/<service_name>/actions/runs/<RUN_ID>
```

**Common failure patterns to look for:**
- **Build failures**: Go compilation errors (show file:line and error), dependency issues (`go get` failures)
- **Docker build failures**: missing files, build arg issues, layer cache problems
- **Deploy failures**: Helm errors, image pull failures, pod crash loops, timeout waiting for rollout
- **Init failures**: invalid inputs, branch not found, permission issues

Do NOT dump raw logs. Always summarize and extract the actionable information.

---

## Important notes

- **NEVER deploy to production** — this is a hard rule, no exceptions
- `env_name` for feature env deployments is always `staging` (the `feature_env_name` parameter controls the feature env)
- The deploy.yml workflow exists on every service repo with the same interface
- If `gh run watch` times out (>10 min), check status with `gh run view` instead
- Do not auto-retry failed deployments — report the failure and let the user decide
