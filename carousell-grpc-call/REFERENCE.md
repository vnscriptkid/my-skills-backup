# Carousell gRPC - Reference Guide

## Environment Contexts

### Feature (feat)
- **Cluster**: gke_carousell-staging_asia-east1-c_staging-feature-k127
- **Region**: asia-east1
- **Use for**: Testing features before staging
- **Namespace**: Typically `default` or `feature`
- **Stability**: Lower - may have breaking changes

### Staging (stage)
- **Cluster**: gke_carousell-staging_asia-east1-c_staging-main-k127
- **Region**: asia-east1
- **Use for**: Pre-production validation
- **Namespace**: Typically `default` or `staging`
- **Stability**: High - mirrors prod structure

### Production (prod)
- **Project**: api-project-11554775814
- **Region**: asia-east1
- **Cluster**: main-a-k127
- **Domain**: gke_thecarousell.com
- **Use for**: Live traffic, real data
- **Stability**: Critical - treat with extreme care
- **⚠️ CAUTION**: All writes are irreversible

## Common Service Pods

Service names typically map to deployment labels. Examples:

| Service | Label | Typical Port | Namespace |
|---|---|---|---|
| UserSvc | `app=user-svc` | 50051 | default |
| CatalogSvc | `app=catalog-svc` | 50052 | default |
| ListingSvc | `app=listing-svc` | 50053 | default |
| OfferSvc | `app=offer-svc` | 50054 | default |

**Finding pods**:
```bash
# List all running services
kubectl get pods -A --sort-by=.metadata.creationTimestamp | tail -20

# Find specific service
kubectl get pods -l app=<service-name>

# Describe pod for details
kubectl describe pod <pod-name>
```

## Proto Contract Lookup

All contracts live in: `github.com/carousell/cs-proto`

**Structure**:
```
cs-proto/
├── proto/
│   ├── user/
│   │   └── v1/
│   │       └── user_service.proto
│   ├── catalog/
│   │   └── v1/
│   │       └── catalog_service.proto
│   └── ...
└── gen/
    └── go/   # Generated Go code
```

**Finding a service**:
1. Identify service name (e.g., UserSvc)
2. Find proto file: `cs-proto/proto/<service-lowercase>/v1/<service>_service.proto`
3. Search for service definition: `service UserService { ... }`
4. Extract method and message types

**Example proto definition**:
```protobuf
service UserService {
  rpc GetUser (GetUserRequest) returns (GetUserResponse);
  rpc UpdateUser (UpdateUserRequest) returns (UpdateUserResponse);
}

message GetUserRequest {
  string user_id = 1;
}

message GetUserResponse {
  User user = 1;
}
```

## Port-Forwarding

### Start forwarding
```bash
kubectl port-forward -n <namespace> <pod-name> <local-port>:<pod-port>
# Example:
kubectl port-forward -n default pod/user-svc-abc123 50051:50051
```

### Verify port is open
```bash
lsof -i :50051
```

### Stop forwarding
Ctrl+C in the forwarding terminal, or:
```bash
pkill -f "kubectl port-forward"
```

## grpcurl Usage

### Basic call
```bash
grpcurl -plaintext -d '{}' localhost:50051 package.Service/Method
```

### With request body
```bash
grpcurl -plaintext \
  -d '{"user_id":"123","status":"ACTIVE"}' \
  localhost:50051 \
  carousell.user.v1.UserService/GetUser
```

### List available services
```bash
grpcurl -plaintext localhost:50051 list
```

### Describe service
```bash
grpcurl -plaintext localhost:50051 describe carousell.user.v1.UserService
```

### Describe method
```bash
grpcurl -plaintext localhost:50051 describe carousell.user.v1.UserService.GetUser
```

## Troubleshooting

### Connection refused
- Port-forward not running: Start it again
- Wrong pod name: List pods and verify
- Wrong port: Check pod's containerPort in kubectl describe

### Method not found
- Service name case-sensitive: Check proto file
- Wrong package: Verify full package path (e.g., `carousell.user.v1`)
- Service not compiled: Verify pod is running correct version

### Request validation fails
- Missing required fields: Check .proto message definition
- Wrong field types: Ensure JSON types match proto types (string, int64, bool, etc.)
- Repeated fields: Use array syntax `[{"item":1}, {"item":2}]`

### Prod caution
- Write operations on prod are permanent
- No undo/rollback for gRPC calls
- Test on stage first
- Require explicit user confirmation before prod writes
- Log all prod interactions

## Quick Commands

Combine these for common workflows:

```bash
# Setup: Install grpcurl
brew install grpcurl

# Test connection to staging
kubectl config use-context gke_carousell-staging_asia-east1-c_staging-main-k127
kubectl get pods -n default | grep svc

# Port-forward and call
kubectl port-forward -n default pod/user-svc-abc 50051:50051 &
grpcurl -plaintext -d '{}' localhost:50051 carousell.user.v1.UserService/ListUsers

# Cleanup
pkill -f "kubectl port-forward"
```
