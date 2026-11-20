---
name: carousell-grpc-call
description: Call Carousell gRPC endpoints with interactive environment and pod selection. Retrieves contracts from cs-proto, guides through request drafting, and handles port-forwarding. Use when testing/debugging gRPC services or calling internal Carousell APIs.
---

# Carousell gRPC Endpoint Caller

Interactive workflow for calling Carousell gRPC endpoints with contract validation and environment-aware port-forwarding.

## Quick start

1. Request: "call the UserSvc gRPC endpoint"
2. Agent guides through:
   - Environment selection (feat/stage/prod)
   - Pod discovery & confirmation
   - Request body drafting from cs-proto contract
   - Final confirmation before send
3. Response shown to user

## Workflow

### Step 1: Verify grpcurl
- Check if grpcurl is installed: `which grpcurl`
- If not: `brew install grpcurl` (macOS) or platform equivalent
- Confirm version: `grpcurl -version`

### Step 2: Environment selection
Present three options and ask user to confirm:

| Environment | Cluster | Use case |
|---|---|---|
| **feat** | `gke_carousell-staging_asia-east1-c_staging-feature-k127` | Feature branches, testing |
| **stage** | `gke_carousell-staging_asia-east1-c_staging-main-k127` | Staging deployments |
| **prod** | `gke_thecarousell.com:api-project-11554775814_asia-east1_main-a-k127` | Production (WRITE CAUTION) |

**For prod write operations**: Ask explicit confirmation with warning about impact.

### Step 3: Service & pod discovery
Once environment confirmed:
- Use kubectl to get current context: `kubectl config current-context`
- Switch to target cluster if needed: `kubectl config use-context <context>`
- List available pods for service: `kubectl get pods -n <namespace> -l app=<service-name>`
- Present pod list, ask user to select/confirm

### Step 4: Port-forward setup
- Start port-forward to selected pod: `kubectl port-forward -n <namespace> <pod-name> 50051:50051`
- Keep forwarding active during request
- Use `localhost:50051` as target for grpcurl

### Step 5: Contract retrieval
- Fetch service contract from cs-proto: `github.com/carousell/cs-proto`
- Identify service, method, and request message type
- Show user the .proto definition for reference

### Step 6: Request body drafting
- Extract request message schema from contract
- Draft example JSON request with all required fields
- Ask user to:
  - Confirm structure is correct
  - Provide actual values (or indicate defaults)
  - Review full request before sending

### Step 7: Send request & show response
Call grpcurl with drafted request:
```bash
grpcurl -plaintext -d '{"field":"value"}' \
  localhost:50051 \
  package.Service/Method
```

Show full response to user with:
- Status code
- Response body
- Any errors or warnings

## Advanced features

See [REFERENCE.md](REFERENCE.md) for:
- Mapping service names to pods
- Common namespaces
- Proto contract examples
- Troubleshooting port-forward issues
