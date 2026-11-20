---
name: test-deploy
description: "Port-forward to a deployed pod on staging/feature env and test endpoints by calling RPCs. Discovers changed RPCs from branch diff, constructs payloads from generated protobufs, validates responses with AI judgment. Usage: /test-deploy [instructions]"
argument-hint: "[instructions or RPC names to test]"
allowed-tools: Read, Write, Bash(git rev-parse *), Bash(git log *), Bash(gh run *), Bash(kubectl get *), Bash(kubectl logs *), Bash(kubectl port-forward *), Bash(gcloud container clusters get-credentials *), Bash(go env *), Bash(go mod *), Bash(go build *), Bash(grpcurl * localhost:*), Bash(curl * localhost:*), Bash(curl * 127.0.0.1:*), Bash(sleep *), Bash(mkdir -p /tmp/services/*), Bash(rm -rf /tmp/services/*)
---

# test-deploy: Port-Forward & Test Deployed Endpoints

You are testing a recently deployed Carousell service by port-forwarding to its pod and calling its RPCs. Your job is to validate that the deployed changes work as expected.

---

## Phase 0: Resolve Context

### Input resolution (priority order):

1. **Explicit user instructions** — service, env, specific RPCs or flows to test
2. **Context from /deploy** — if chained after a successful deploy, service/branch/env are already known
3. **Infer from environment** — service name from cwd (last segment of repo path), branch from `git rev-parse --abbrev-ref HEAD`, ask user for environment

### Environment resolution:

Ask the user: "Test on **staging** or a **feature environment**?" (unless already known from /deploy chain or explicit instructions).

### Connect to the correct GKE cluster:

| Environment | Command | Namespace |
|---|---|---|
| Staging | `gcloud container clusters get-credentials staging-main-k127 --zone asia-east1-c --project carousell-staging` | `<SERVICE>` (the system name) |
| Feature env | `gcloud container clusters get-credentials staging-feature-k127 --zone asia-east1-c --project carousell-staging` | `<FEATURE_ENV_NAME>` |

### Find the running pod:

```bash
kubectl get pods -n <NAMESPACE> -l app=<SERVICE> --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'
```

If no running pod found, fall back to:
```bash
kubectl get pods -n <NAMESPACE> | grep <SERVICE>
```

Report the pod status. If the pod is not running (CrashLoopBackOff, Pending, etc.), STOP and suggest using `/debug-deploy` instead.

### Read container ports:

```bash
kubectl get pod <POD> -n <NAMESPACE> -o jsonpath='{.spec.containers[*].ports[*]}'
```

Map port names to protocols (grpc, http, metrics). Store the port mappings.

### Proto source resolution:

1. Read `go.mod` in the service repo to find the `cs-proto-gen-go` version
2. Check if the generated proto types exist in the local Go module cache: `go env GOMODCACHE` then look for the module directory
3. If not cached, run `go mod download github.com/carousell/cs-proto-gen-go` in the service repo
4. If proto annotations are needed (to determine protocol per RPC), clone the correct version of `cs-proto` to `/tmp/services/cs-proto`:
   ```bash
   mkdir -p /tmp/services
   git clone --depth 1 https://github.com/carousell/cs-proto.git /tmp/services/cs-proto
   ```
5. Read proto files to determine protocol annotations (`PROTOCOL_GRPC` vs `PROTOCOL_HTTP`) per RPC

### Confirm with the user:

```
Test plan:
  Service:     <service_name>
  Branch:      <branch>
  Environment: <staging | feature: feature_env_name>
  Pod:         <pod_name>
  Ports:       grpc:<port>, http:<port>

Proceeding to discover RPCs to test...
```

---

## Phase 1: Test Discovery

### When NO explicit instructions given:

1. **Get branch diff:**
   ```bash
   git log master..<BRANCH> --oneline --stat
   ```

2. **Identify changed handler files** — look for changes in directories like `internal/components/`, `internal/handlers/`, `internal/services/`, or any file that implements RPC methods.

3. **Map changed handlers to RPCs:**
   - Read the service's `main.go` to find `RegisterService` calls and which service descriptors are registered
   - Read the proto service definitions to find RPC method names
   - Cross-reference: which RPC implementations were modified on this branch?

4. **For each identified RPC:**
   - Read the proto annotation for protocol (gRPC or HTTP)
   - Read the generated Go protobuf struct for request/response message types
   - Understand the fields, types, and enums available

### When explicit instructions given:

Skip discovery. Use the user's specified RPCs/flows directly. Still resolve proto types for payload construction.

### Present the test plan:

```
RPCs to test:
  1. SemanticaInternalService/ReceiveMessage (gRPC) — handler changed in this branch
  2. SemanticaPublicService/SearchThemes (HTTP) — new RPC added

Proceed with testing? (y/n)
```

Wait for user confirmation before proceeding.

---

## Phase 2: Port-Forward & Build Test Harness

### Port-forward:

1. Pick a local port starting from a high range (e.g., 18080, 18081, etc.) to avoid conflicts with common services.

2. Start the port-forward using `run_in_background`:
   ```bash
   kubectl port-forward <POD> <LOCAL_PORT>:<CONTAINER_PORT> -n <NAMESPACE>
   ```
   Run this via the Bash tool with `run_in_background: true`. The port-forward will automatically terminate when the session ends.

3. If both gRPC and HTTP ports are needed, forward both on separate local ports.

4. Wait 2 seconds, then verify the tunnel is up by making a test connection:
   ```bash
   curl -s -o /dev/null -w '%{http_code}' http://localhost:<LOCAL_PORT>/healthz
   ```
   Or for gRPC: `grpcurl -plaintext localhost:<LOCAL_PORT> list`

5. **If the port is already in use** (port-forward fails with "bind: address already in use"):
   - Try the next port (e.g., 18082, 18083)
   - If 3 consecutive ports fail, ask the user to free the port or specify one manually
   - Do NOT attempt to kill existing processes on the port

### Build the test harness:

**Strategy A (preferred): Extend existing client**

Check if the service has an existing client binary (e.g., `internal/cmd/client/main.go` or similar):
- If it exists, read it and understand the client setup
- Add new functions for the RPCs that need testing
- The new functions should accept the local port as a parameter
- Build: `go build -o /tmp/services/<SERVICE>_client ./internal/cmd/client`

**Strategy B (fallback): Temporary Go test file**

If no existing client:
1. Create `/tmp/services/<SERVICE>_test/main.go`
2. Import the generated proto types from `cs-proto-gen-go`
3. Set up a gRPC dial to `localhost:<LOCAL_PORT>` (with `grpc.WithTransportCredentials(insecure.NewCredentials())`)
4. For HTTP endpoints, use `net/http` client targeting `localhost:<LOCAL_PORT>`
5. Initialize the service client stub from the generated proto package
6. Copy `go.mod` and `go.sum` from the service repo as a starting point, then `go mod tidy`
7. Build: `go build -o /tmp/services/<SERVICE>_test/test_client /tmp/services/<SERVICE>_test/`

### Payload construction:

1. **Check existing test files** — look for `_test.go` files in the repo that construct request objects for the target RPCs. Reuse those payloads if found.
2. **AI-crafted payloads** — if no test fixtures exist:
   - Read the generated Go protobuf struct from the module cache to know exact fields, types, and enum values
   - Read the handler implementation to understand what fields are actually used and validated
   - Craft realistic payloads: valid enum values, reasonable string values, properly structured nested messages
   - For scenario tests, plan how outputs from one call feed into the next

---

## Phase 3: Execute Tests & Validate

### Smoke tests (run first):

For each identified RPC:

1. Call the RPC with the constructed payload
2. Capture: response body, error/status, latency
3. **Pass criteria:**
   - gRPC: no error status (or expected error for edge-case tests)
   - HTTP: no 5xx status code
   - Response has non-empty, meaningful fields

### Scenario tests (when applicable):

- Read the handler code to understand if RPCs have dependencies (e.g., create before get, write before read)
- Chain calls in logical order, passing outputs from one as inputs to the next
- Example flow: CreateTheme -> GetTheme (using returned ID) -> SearchThemes (verify it appears)

### Validation per call:

1. **Error check** — gRPC status codes, HTTP status codes
2. **Response structure** — non-empty, expected fields present
3. **AI judgment** — read the handler code, evaluate whether the response makes sense:
   - Does the response match what the code path should return?
   - Are there unexpected empty fields that should have data?
   - Could this be an env/data issue vs a code bug?
4. **Explicit assertions** — if the user specified expected outcomes, check those

### Early exit:

If a smoke test fails with a clear error (`Unimplemented`, connection refused, `UNAVAILABLE`), report immediately. Skip scenario tests that depend on the failed RPC.

### Output per call:

```
RPC: SemanticaInternalService/ReceiveMessage (gRPC)
Status: OK (142ms)
Request:  {message_id: "test-123", sender_id: 1001, ...}
Response: {status: DELIVERED, processed_at: "2024-..."}
Validation: Response looks correct — handler processes message and returns delivery status
```

---

## Phase 4: Results & Cleanup

### Present results summary:

```
Test Results for <SERVICE> (<ENVIRONMENT>)
Branch: <BRANCH>

Smoke Tests:
  [checkmark] RPC/Method1  (Nms) — brief validation note
  [x] RPC/Method2  (Nms) — error: <status code and message>
  [skipped] RPC/Method3  — skipped (depends on Method2)

Scenario Tests:
  [checkmark] Flow name  (N calls, Nms total)
  [x] Flow name  — blocked by Method2 failure

Issues Found:
  1. <Description of issue, whether it's likely a code bug or env/data issue>
  2. <Description>

Overall: N/M RPCs passed. <Summary assessment>
```

### Cleanup (automatic, always run):

1. **Port-forward**: No cleanup needed — the background port-forward process terminates automatically when the session ends.

2. **Delete temporary test files:**
   ```bash
   rm -rf /tmp/services/<SERVICE>_test/
   ```

3. **Clean up cloned repos:**
   ```bash
   rm -rf /tmp/services/cs-proto/
   ```

4. **Preserve client additions** — if functions were added to an existing client binary (`internal/cmd/client/`), leave them in place. They are useful for future testing.

### When chained from /deploy:

Present the test results as a seamless continuation of the deploy output. The user should see one continuous flow: deploy succeeded -> testing endpoints -> results.

---

## Important Notes

- **Always confirm the test plan** with the user before executing tests (Phase 1 output)
- **Never modify production pods** — this skill only works with staging and feature environments
- **Port-forward cleanup** — port-forwards run via `run_in_background` and terminate automatically when the session ends. No manual cleanup needed.
- **Temporary files go in /tmp/services/** — never create test artifacts in the service repo itself (except when extending an existing client)
- **If the pod is unhealthy**, stop and suggest `/debug-deploy` instead of trying to test
- **Do not dump raw responses** — summarize and extract meaningful information, similar to how `/debug-deploy` handles logs
- **gRPC reflection** — if the service supports gRPC reflection, you can use `grpcurl` as a quick alternative to building a Go client. Check with: `grpcurl -plaintext localhost:<PORT> list`
- **Timeouts** — set reasonable timeouts for RPC calls (10s default). If a call hangs, kill it and report as a timeout.
- **If tests reveal issues**, present them clearly but do NOT auto-fix. Ask the user what they want to do.
