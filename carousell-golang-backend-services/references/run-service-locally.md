# Running service locally with mirrord

Run a Carousell golang backend service locally, using mirrord to route the local process's network traffic through a target pod in the cluster. This lets the local process reach staging dependencies (DBs, other services) with the pod's network identity.

## Prerequisites

### Kube context + namespace

Requirements:
- Must be a FEATURE ENV context. **Hard constraint: mirrord CANNOT run on stage/prod** -- developers lack permission to create pods there, so it will fail. Feature env is mandatory.
- The feature-env kube context is `gke_carousell-staging_asia-east1-c_staging-feature-k127`.
- The namespace must be a feature env that CONTAINS a pod of the service being run locally. One namespace in the feature-env cluster = one feature env.

Procedure:
1. Check the current context + namespace and whether it has the service's pod: `kubectl get pods` (lists pods in the current context+namespace).
2. Decision:
   - If the current context is `gke_carousell-staging_asia-east1-c_staging-feature-k127` AND `kubectl get pods` shows a pod of the target service -> good, proceed.
   - Otherwise (not a feature env, or a feature env without the service) -> STOP and present the user two options (AskUserQuestion-style):
     1. **Provide a feature env**: the user gives a namespace to use.
     2. **Search for one**: `kubectl get pods --context gke_carousell-staging_asia-east1-c_staging-feature-k127 --all-namespaces | grep <service-name>`
3. Once the namespace is chosen, set it on the current context:
   ```
   kubectl config set-context --current --namespace <ns>
   ```

**The mirrord target pod's namespace does NOT have to be the feature env whose dependencies you want to call.** These are two separate concerns:
- The target pod only supplies the local process's network identity -- it just has to be a pod of the service being run locally, in any feature env.
- Which feature env's *dependencies* get called is decided per-request by the `c-tenancy` header (see Calling APIs below), not by the target pod.

So when the feature env with the dependency you need has no pod of your service, target any feature env that does have one, and pass `c-tenancy: <dependency's feature env>` on your requests. Do NOT resolve this by overriding the dependency's `hostPort` in `/opt/config/<service-name>.yml`.

### Config file

The service reads its config from `/opt/config/<service-name>.yml` (part of the CTF config system -- see Config Management in the main skill). Prepare it before running. Follow these steps in order.

1. **Determine the service name** (see Service name in the main skill).

2. **Check for an existing config file** at `/opt/config/<service-name>.yml`:
   - Does not exist -> go to step 3.
   - Exists -> `stat` it, show the user its creation + modification times, and ask whether to **Replace** with the latest staging config (step 3) or **Keep** the existing file (skip to step 4).

3. **Download the latest staging config:**
   ```bash
   devctl config load --system=<service-name> --env=staging > /opt/config/<service-name>.yml
   ```

4. **Add new config keys from the feature branch.** Check whether the branch added keys not in staging:
   ```bash
   git diff master -- config-template.yml
   ```
   If new keys were added: for each, use the default value from `config-template.yml` if one is defined, otherwise ask the user. Add the key-value pairs to `/opt/config/<service-name>.yml`. If the branch added no new keys, skip this step.

   Expand any composite types (e.g. `!GRPC_SERVICE`, `!REDIS`) into their sub-fields. Treat any tag that isn't an obvious primitive as a possible composite type and look up its shape. 

   **Do NOT include type tags** (`!INT`, `!DURATION`, `!REDIS`, etc.) when writing values -- they are optional and some (e.g. `!INT`) break parsing.

5. **Validate.** Compare `/opt/config/<service-name>.yml` against `config-template.yml` and flag any keys defined in the template but missing from the config file. Compare key names only -- ignore type tags and default values.

## Run service command

```
mirrord exec -f .mirrord/mirrord-egress-only.json --target pod/<service-pod-name> -- go run internal/cmd/<service-name>/*.go
```

Notes:
- Get `<service-pod-name>` explicitly: run `kubectl get pods` (in the chosen context+namespace) and find the pod for the service -- its name starts with the service name (e.g. `merchant-invoice-5cbdc55f98-mb6df`). Substitute that exact literal name into `--target pod/...`.
- `.mirrord/mirrord-egress-only.json` is a mirrord config with outgoing network on, incoming off (egress only).  Contents:
  ```json
  {
      "feature": {
          "env": { "exclude": "GOPATH" },
          "network": { "incoming": false, "outgoing": true }
      },
      "telemetry": false
  }
  ```
- If the file doesn't exist, try `~/mirrord-configs/mirrord-egress-only.json` instead. If neither exists, offer to create `.mirrord/mirrord-egress-only.json`.
- The entry point package is under `internal/cmd/<service-name>/` (the main backend service entry point -- see Project Structure in the main skill).
- Run with the repo root as the working directory.
- Service startup takes at least several seconds. Watch the logs until it reports it is serving before calling any API.

## Calling APIs

**Set `c-tenancy: <feature-env-name>` on every request** whose downstream calls should hit a feature env's services (see Feature env routing in the main skill). Without it, the local service calls staging, and a staging service missing a new RPC fails with `Unimplemented: unknown service <proto.Service>`.

- HTTP: `curl -H 'c-tenancy: <env>' ...`
- gRPC: request metadata -- `metadata.AppendToOutgoingContext(ctx, "c-tenancy", "<env>")`. Existing throwaway clients often already have a `-c-tenancy` flag; check before adding one.

Use the `internal/cmd/client/` throwaway client script as a reference.
If there are no uncommited changes for the APIs you need, edit `internal/cmd/client/*.go` directly. Otherwise, check with the user whether they want to (1) edit the script directly, losing the current unstaged changes or (2) create a separate throwaway script for this round of testing.

# Debugging service locally

Same as above, but attach the Delve debugger via the `mcp-dap-server` MCP server (exposes DAP debugging as MCP tools: `debug`, `breakpoint`, `continue`, `step`, `context`, `evaluate`, `stop`, etc.).

All prerequisites from the run section above apply unchanged (feature-env kube context + namespace, `/opt/config` config file).

The only change vs running normally: mirrord wraps **`dlv dap`** (the Delve DAP server) instead of `go run`. dlv then builds AND launches the service itself, so the service inherits mirrord's network interception. The MCP `mcp-dap-server` connects to dlv over TCP using "connect mode".

So the run command becomes:
```
mirrord exec -f .mirrord/mirrord-egress-only.json --target pod/<service-pod-name> -- dlv dap --listen 127.0.0.1:2345
```
`--` separates mirrord's args from the wrapped command. Port 2345 is arbitrary but conventional for dlv.

If the user does not have `mcp-dap-server` installed, offer to install it from <https://github.com/chloelee767/mcp-dap-server/tree/feat/connect-external-dap-server>. Warn the user that it is experimental.

## Step by step

**Backgrounding long-running commands:** the `mirrord exec ...` process runs until killed. Do NOT background it with `&` -- a shell-backgrounded process is unreliable to stop (e.g. wrong `pkill` search string). Use your agent's managed backgrounding instead, so you get a reliable handle to stop it later. To read logs while it runs, redirect output to a file: `mirrord exec ... > /tmp/dlv.log`.
  - Claude Code: use the bash tool's `run_in_background:true` -- stop it with `TaskStop`, and it stops automatically when Claude closes.

1. Run the `mirrord exec ... -- dlv dap --listen 127.0.0.1:2345` command in the background (see the backgrounding note above). Run with the repo root as the working directory.
2. Poll until dlv is actually listening -- mirrord setup takes ~10-15s before dlv binds the port. Check the log for `DAP server listening at: 127.0.0.1:2345` AND that the TCP port is in LISTEN state (e.g. `lsof -nP -iTCP:2345 -sTCP:LISTEN`). Do not proceed until both are true.
3. Call the MCP `debug` tool with:
   - `mode`: `source`
   - `path`: absolute path to the entry point package dir, e.g. `/Users/name/go/src/github.com/carousell/merchant-invoice/internal/cmd/merchant-invoice`
   - `connectAddr`: `127.0.0.1:2345`
   - `breakpoints`: list with the file (absolute path) + line of the RPC handler to break in, e.g. `get_transactions.go:30` (first statement inside the handler body, NOT the func signature line)
   - `stopOnEntry`: `true`

   When this returns, dlv has built + launched the service under mirrord and the breakpoint is set. NOTE: the build takes ~20s and happens during/after this call -- the service is NOT serving traffic yet.
4. Trigger the breakpoint. The service only starts serving once you `continue`, and `continue` BLOCKS the MCP turn until a breakpoint hits or the program terminates. 2 options:
  - Option 1: call MCP tool `continue` from one background agent, call the API client from another background agent
  - Option 2: arrange for the API call to happen WHILE `continue` is in flight, from a SEPARATE OS process. Eg. schedule the API client call in a background shell with a delay (~20s, to let dlv finish building and the service start serving after continue), THEN call the MCP `continue` tool.
5. `continue` returns when the breakpoint hits, giving full context: location, the entire gRPC interceptor stack trace down to the handler, and local variables.
6. Debug normally with MCP tools: `evaluate` expressions (e.g. `req.UserId` returned `"53311"`), `step` (over/in/out), `context`, set more `breakpoint`s, etc.
7. When done, `continue` to let the RPC finish (the client receives a valid response), then `stop`. In connect mode `stop` disconnects gracefully WITHOUT killing the external dlv/mirrord process (`Disconnected from external DAP server`). Clean up the mirrord+dlv background process yourself afterward: stop the task you started in step 1 via its managed handle (see the backgrounding note above), not `pkill`.

## Common mistakes

- **`continue` is blocking and holds a mutex.** All MCP dap tool calls are serialized. `continue` does not return until a breakpoint hits or the program terminates. If you call `continue` then try to call ANOTHER MCP tool to trigger traffic, you deadlock-wait -- the traffic-triggering call queues behind the still-running `continue`. The API call that triggers the breakpoint MUST come from a separate OS process (background shell), NOT another MCP tool call.
- **Startup race / timing.** After `continue`, dlv still needs to finish compiling (if not already) and the service needs to bind + start serving (~20s total observed). If the API client fires before the service is serving, it gets connection refused / timeout and the breakpoint never hits. This "looks like the debugger is broken" but is just a timing race. Add a delay before the client call, or poll for readiness.
- **Use `source` mode, not `binary`/`attach`.** In source mode dlv builds and runs the program inside the mirrord-wrapped process, so the debuggee inherits mirrord interception. Attach mode would attach to an already-running process -- not what we want, since mirrord is wrapping dlv, not the service.
- **Harmless dlv log noise on ARM Macs:** lines like `Could not read register zt0/p13/svcr/za/tpidr2: protocol error E97 during register read` are NON-FATAL ARM SME/SVE register reads dlv can't do over the transport. Ignore them -- they do not indicate failure.
- **Harmless mirrord noise:** a `Proxy error, connectivity issue or a bug: connection closed` from mirrord-intproxy may appear AFTER the RPC completes (mirrord's outgoing proxy tearing down). Not a DAP problem.
- **"Program terminated" from a final `continue` is expected** -- the debuggee process exited after the request flow completed. It does not mean an error.
- Breakpoint file paths and `path` must be ABSOLUTE paths.
