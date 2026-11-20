---
name: carousell-grpc-test
description: Safely test Carousell gRPC endpoints with grpcurl through Kubernetes port-forwarding. Use when a user asks to call, test, inspect, or debug a Carousell gRPC RPC in a Kubernetes environment.
---

# Test Carousell gRPC Endpoints

Test one RPC at a time. Treat every unknown endpoint as write-capable until its contract proves otherwise.

## Required inputs

Collect:

- RPC name
- Request field values
- Kubernetes context
- Target environment when it is not clear from the context

Every request field and value must come from the user or be explicitly confirmed by the user before sending. Do not infer request data from code, examples, previous calls, repository state, naming conventions, common defaults, or other context.

This requirement includes omitted fields and protobuf defaults. Explicitly show and confirm when a field will be omitted or sent as an empty, zero, false, default enum, or default message value.

## Workflow

### 1. Inspect the protobuf contract

1. Find the RPC under a workspace's `cs-proto/proto/` directory.
2. Read its service, package, request, response, imports, and method annotation.
3. Classify it from `common_annotations.api_method_annotation.operation_type`:
   - `OPERATION_TYPE_READ`: read-only
   - Any write/create/update/delete operation: write
   - Missing or unclear annotation: treat as write
4. Read nested message and enum definitions needed to construct the request.
5. Inspect the server implementation only when needed to determine practical requirements not expressed by proto validation, such as required country code or resource ownership.
6. List all request fields, identify required and optional fields, and ask the user for every value or omission that has not already been explicitly supplied.
7. Summarize the classification and confirmed inputs to the user.

Never invoke the RPC during contract discovery.

### 2. Apply extra safeguards to write endpoints

For a write-capable or unknown endpoint:

1. State clearly that it may mutate data.
2. Explain the likely side effect and identify the target environment.
3. Show the intended resource identifiers.
4. Ask for explicit confirmation to continue toward execution.

This is an additional gate. A final request confirmation is still mandatory in step 5.

### 3. Find the server safely

Use read-only `kubectl` commands with the exact context supplied by the user:

```bash
kubectl --context '<context>' get pods -A -o wide
kubectl --context '<context>' -n '<namespace>' get svc -o wide
kubectl --context '<context>' -n '<namespace>' get pod '<pod>' -o jsonpath='{range .spec.containers[*]}{.name}{" ports="}{range .ports[*]}{.name}{":"}{.containerPort}{" "}{end}{"\n"}{end}'
```

Filter results locally with `rg` when useful. Select a Running application pod matching the protobuf service; do not select a database, worker, or HTTP-only pod. Prefer a pod selected by the stable service when stable/canary labels differ.

If the service-to-pod mapping or gRPC port is uncertain, stop and ask the user.

### 4. Confirm and start port-forwarding

Choose an unused local port. Before starting, show the exact command and ask for confirmation:

```bash
kubectl --context '<context>' -n '<namespace>' port-forward pod/<pod> <local-port>:<grpc-port>
```

Only run it after approval. Start it as a background task and verify output contains `Forwarding from`. If startup fails, report the error and do not call the RPC.

### 5. Build and confirm the grpcurl request

Prefer local protobuf files over server reflection:

```bash
grpcurl -plaintext \
  -import-path '<absolute-or-repo-relative-path-to-cs-proto/proto>' \
  -proto '<proto-path-relative-to-import-root>' \
  -d '<json-request>' \
  localhost:<local-port> \
  '<package>.<service>/<rpc>'
```

Do not assume `-plaintext`; verify it from the service configuration or established local client pattern. Adjust transport flags when the endpoint requires TLS.

Before every RPC invocation:

1. Show the full RPC method.
2. Show the exact JSON request, formatted for review.
3. List fields omitted from JSON and the protobuf defaults they will receive.
4. State that no request value or omission will be assumed and ask the user to verify every field.
5. State whether it is read-only or write-capable.
6. For writes, repeat the environment and expected side effect.
7. Ask for explicit confirmation to send the exact displayed data.

Do not execute on vague approval given before the exact request and omissions were shown. Any changed value, added field, removed field, or changed omission requires fresh confirmation.

### 6. Execute once and report

After final approval, execute the displayed request exactly once. Do not retry write endpoints unless the user separately confirms the retry after seeing the error.

Report:

- Success or gRPC error/status
- The server response
- A short summary of important fields when helpful

Do not save responses to repository files. Avoid unnecessarily repeating tokens, signatures, credentials, or sensitive user data; identify such fields and redact them in summaries while preserving the fact that they were returned.

### 7. Clean up

Stop the port-forward after the request completes or fails. Confirm cleanup briefly. Do not leave background port-forward processes running.

## Non-negotiable safety rules

- Never call an endpoint before inspecting its protobuf contract.
- Never assume, infer, invent, or silently default request data.
- Never send any field value or omission that the user has not explicitly confirmed.
- Never port-forward without showing the command and receiving confirmation.
- Never send a gRPC request without showing the exact request, all omissions/defaults, and receiving final confirmation.
- Never silently switch Kubernetes contexts, namespaces, environments, pods, ports, RPCs, or request data.
- Never use production for a write test unless the user explicitly confirms production after the mutation risk is stated.
- Never broaden a test into multiple requests without separate approval.
