---
name: carousell-golang-backend-services
description: CLAUDE.md / AGENTS.md for Carousell golang backend services. MUST load before reading ANY code or making ANY code changes in a service — even when following a user-provided plan. Use whenever writing, reading, or exploring Go code, `config-template.yml`, migration files, or any other files in the codebase; discussing or planning implementation; or asking about deployment, config management, architecture, libraries or code conventions. ALSO use for these operational tasks, even mid-task as a sub-step of something larger: running/starting/debugging a service locally (incl. against staging, mirrord); fetching/checking the current value of a config or feature flag for an environment (prod/staging/feature). Contains rules that override naive approaches (e.g. `make run`, `go run` to start a service, and grepping `config-template.yml` for live config values are all WRONG).
---

# Carousell Golang Backend Services

## Identifying a Carousell Golang Backend Service

Look for these indicators:
- `github.com/carousell/` imports in Go files
- `config-template.yml` in the repo root — note: absence doesn't rule it out (older services may not have it)

## Commands

Build and test with the standard `go build ./...` / `go test ./...`.

Do NOT use these commands, they are out of date or don't work properly locally:
- `make run` or `./run.sh`
- `make proto`
- `make localenv`
- `make lint`
- `make cover`
- `./pr_check.sh`

## Project Structure

**Folder structure:** Many repos have a top level folder that is the same as the service name which contains all the `.go` files. For example: `$GO_SRC/github.com/carousell/ListingQuota` repo has a folder `$GO_SRC/github.com/carousell/ListingQuota/ListingQuota`.

**Executables (`main` packages):** `**/cmd/**` folder -- contains both important entry points and one off scripts. Common executables:
- `**/cmd/svc-name/` (or `**/cmd/server/` in older services): entry point for main backend service 
- `**/cmd/svc-name-worker/` (or `**/cmd/worker` in older services): entry point for persistent worker service. It doesn't serve any traffic, it typically runs various periodic tasks.
- `**/cmd/client/`: throwaway client script used to call APIs during development. Ignore code quality here.
- `**/cmd/job-name/`: executable for kubecron jobs

**External dependencies** (eg. clients to other microservices) are typically in the `external/` folder.

**Service name:** used by `devctl`, kube, the service explorer MCP, etc. Derive it:
- Newer services: the repo directory name (e.g. `merchant-invoice`).
- Older CamelCase repos: lowercase kebab-case (e.g. `ListingQuota` -> `listing-quota`).
- To verify the service name, use the carousell-service-explorer MCP

### Postgres Database Migration

Typical folder structure:
- Migration .sql files directory: `migration/pg/`
- Migration client script: `migration/migrationClient.go`

Migration client typically uses `github.com/carousell/go-utils/migrator` (based on `github.com/golang-migrate/migrate`).

How migrations work:
- Migration files are numbered. Some repositories use sequential numbers (more common) -- e.g., `001_create_table.up.sql`, `002_add_column.up.sql`. Other repositories use date based numbering (eg. `20190123_create_table.up.sql`, `20191001_add_column.up.sql`)
- Each migration has an `.up.sql` (apply changes) and optionally `.down.sql` (rollback changes) file. Different services have different conventions around when to include `.down.sql` (some services do not use `.down.sql` at all), check each service to understand the convention.
- Applied migrations are tracked in a `schema_migrations` table
- Migrations run in order based on version number

Use cases for migrations:
- Schema changes (eg. adding/removing columns, tables, indexes, constraints)
- Inserting/updating data which is not possible to do via API
- Small-scale data backfilling

Common mistakes:
- **Schema evolution**: When looking up table schema, remember that columns may be added/removed across multiple migration files, not just the initial `CREATE TABLE` statement. Check all relevant migration files to understand the current schema. Tip: To find all migrations affecting a table, search for the table name across all migration files in `migration/pg/`

## Config Management

When the user refers to a "config" (eg. move something to config, add a config), they mean an internal system called CTF config management, which sets different config values per environment (prod, staging, feature env).

Read `references/ctf-config-guide.md` before you:
- **want to read/fetch/check the current value of a config for an environment** (prod/staging/feature), even as a one-off mid-task. Do NOT grep `config-template.yml` for the value -- it holds templated defaults, not live per-env values.
- make ANY config change (add/remove/rename etc), or update config values for an environment
- understand any of these things related to CTF config management: `config-template.yml`, `devctl config ...` commands, `github.com/carousell/go-utils/configloader`

## Feature flags / Experiments

- The feature flagging service is known as cx service (cxsvc) or experiment svc.
- Flag rules can match on: user ID, user attributes, platform (ie. client frontend), build number.
- Prod and staging cxsvc may have different flag values. Feature env has no separate values -- it uses staging's.
- A flag's response has 2 distinct concepts -- don't conflate them:
  - **Segment**: the value assigned by the rules, typically "control" or "treatment" (sometimes "treatment_a", "treatment_b", etc.).
  - **Enabled/disabled**: whether the flag as a whole is on -- ie. whether cxsvc returns a segment instead of an error when a backend service asks for it. Rarely used; flags are almost always enabled.
  - Watch out: the user may colloquially say "enabled/disabled" to mean the segment value ("treatment"/"control").
- Use the cxsvc MCP to check flag values.

## Protobuf & API Contracts

Services use protobuf for APIs. Usually, it's either gRPC+Protobuf (more common) or Protobuf-Over-HTTP.

There are 2 different systems for generating and managing protobufs. To identify which system is used:

- ✅ **CTF Proto Management**: Imports from `github.com/carousell/cs-proto-gen-go/` or `github.com/carousell/grp-proto-gen-go/`
  - **Load the `carousell-proto-ctf` skill** whenever working with protos — it has the repo paths, workflows for exploring proto contracts, and the commands for fetching generated Go code. This includes implementing gRPC clients, understanding another service's API, or working with a proto branch.
- ✅ **Legacy shared-proto management:** Has `pb/` folder with committed `.pb.go` files
  - Generated `.pb.go` files are committed to each backend service's repository, typically in the `pb/` folder.
  - `.pb.go` files are generated using the `./generate_protobufs.sh` script in each backend service.
  - The proto files are found at <https://github.com/carousell/shared-proto>.

## Messaging service

An internal message broker for async, decoupled communication between services. Two distinct features run over it (see below): **pub/sub messages** and **async calls**.
- **pub/sub messages:** Publish a message under a `msgType`; the broker fans it out to all services subscribed to that type. Senders and receivers are decoupled.
- **async calls:** Invoke a gRPC method (your own service's or another's) indirectly through the broker instead of calling it directly, either immediately or at a future time. Use to offload slower work that must succeed (broker retries) or must run later.

Read `references/messaging-svc.md` before implementing pub/sub or async calls, deciding whether to use messaging-svc, or to understand its conventions and pitfalls. Also read it if you encounter any of these libraries in code — they all relate to messaging-svc and many services wrap them (eg. `service/messaging/`):
- `github.com/carousell/go-messaging-client/publisher`
- `github.com/carousell/go-messaging-client/asynccall`
- `github.com/carousell/grp-proto-gen-go/messaging/client/public`
- `github.com/carousell/go-utils/dalutils` -- specifically the CDC (change data capture) / transactional outbox methods

## Code Style & Conventions

### Misc

- **Imports order**: `goimports -local 'github.com/carousell'`
- **Types**: Define interfaces in `types.go` files
- **Architecture**: Service-oriented with dependency injection via constructors
- Do not use the dial timeout config for hystrix command timeouts -- a common mistake in existing code; don't copy it.
- Do not add nil checks for injected dependencies (eg. `if mgr.svcXClient != nil { ... }`). It clutters the code and silently hides missing dependencies that tests would otherwise catch.

### Error Handling

- Wrap errors using `errors.Wrap`
- Prefer `github.com/pkg/errors`
- Some code may use an internal package `github.com/carousell/Orion/utils/errors` or `github.com/carousell/go-utils/errors` instead of `github.com/pkg/errors`. Note that they don't have a `Wrapf` function, so use `Wrap` with `fmt.Sprintf` instead.
- Always wrap errors, even from helper functions
- **Do not pass error message format strings as function parameters.** Instead, have the callee return a generic wrapped error, and let the caller wrap it with context-specific messaging:
  Bad:
  ```go
  func getExcludedIds(ctx context.Context, id string, errMsgFmt string) ([]string, error) {
      return nil, errors.Wrap(err, fmt.Sprintf(errMsgFmt, id))
  }
  // in caller:
  ids, err := getExcludedIds(ctx, id, "[Caller] failed to get excluded ids %s")
  ```

  Good:
  ```go
  func getExcludedIds(ctx context.Context, id string) ([]string, error) {
      return nil, errors.Wrap(err, "failed to get excluded ids")
  }
  // in caller:
  ids, err := getExcludedIds(ctx, id)
  if err != nil {
      return nil, errors.Wrap(err, fmt.Sprintf("[Caller] failed to get excluded ids %s", id))
  }
  ```

### Endpoint Error Codes

For gRPC / HTTP endpoints, return the appropriate error code (e.g. `InvalidArgument` / HTTP 4XX) so error dashboards show useful data. The default when no code is specified is `InternalError` / HTTP 500, so only set a code when you want something else.

### Logging

We have a company library for printing structed logs. There are a few possible import paths for it, it has been copied/moved a few times:
- `github.com/carousell/go-logging` (latest)
- `github.com/carousell/Orion/utils/log`

Use the same logging library that the rest of the code uses, don't use a different one (even if the output is the same).

The API is `func Error(context.Context, interface{}...)`, similarly for `Warn`, `Info` etc

The usage is `log.Error(ctx, "key1", <value 1>, "key2", <value 2>)` where the values can be any type of object.

Ensure that key-value pairs are appropriately given. Common mistakes:

```go
// ❌ Bad: unmatched key-value pairs (missing keys)
log.Error(ctx, "value1", "value2")
log.Error(ctx, "key1", "value1", "value2")

// ✅ Good: proper key-value pairs
log.Error(ctx, "key1", "value1", "key2", "value2")
log.Error(ctx, "error", err, "userID", userID, "listingID", listingID)
```

### Metrics

See `references/metrics.md`. Use it when adding, updating, or designing prometheus metrics for a flow or API (e.g. for health monitoring or proactive alerting). It covers what to instrument, metric type and labels, and the `metrics.go` layout convention.

### Business logic involving time

- Ensure tests are robust and will work when run at any date + time
- Avoid using `time.Until(..)` and similar functions directly. Instead, make the current time an input argument so tests can hardcode it.
- Default seam: keep `now time.Time` off the public signature. The public method calls `time.Now()` and immediately delegates to an unexported helper that takes `now`; test the helper with a hardcoded time. Widen the public signature itself only if the caller already owns the time for another reason (eg. a sibling method on the same interface takes it too).

### Using Generated Protobuf Code (*.pb.go / cs-proto-gen-go / grp-proto-gen-go)

- Getter functions on autogenerated protobuf structs in pb.go will check for nil. Eg. `someProtoReq.GetSeller().GetUserDetails().GetId()` won't panic if seller or user details is null, it will simply return an empty string. Do note that only protobuf generated code is guaranteed to do this, not all getter functions.

### Proto Transformer Functions

When writing transformer functions that convert between proto types (e.g. `transformFoo(in *srcproto.Foo) *dstproto.Foo`), always guard against a nil input at the top of the function and return nil:

```go
func transformFoo(in *srcproto.Foo) *dstproto.Foo {
    if in == nil {
        return nil
    }
    // ... rest of transformation
}
```

Without this guard, passing a nil pointer will not panic (proto getters are nil-safe), but the function will return a fully-initialised struct with all zero/default values instead of nil — which can cause unexpected behaviour in callers that check for nil to determine whether a field is present.

For transformation of non-protobuf types, it's not necessary to return nil -- use what makes sense for the context.

### Postgres Schema Design

- **No array types**: Do not use Postgres array types (e.g. `TEXT[]`, `INT[]`). They are not supported by internal tooling such as datareplicator.
- **Backwards compatibility for new columns**: After adding a new column, existing rows have `NULL` and old pods (still running during canary) won't write it either. Queries filtering on that column will silently exclude those rows. Add an `OR col IS NULL` condition where appropriate. Do ensure this `IS NULL` check is appropriately parameterised.

### Postgres Queries & DAL

- Parameterise filter values: Use `$N` placeholders for filter values — don't hardcode string literals in the query (e.g. `WHERE col = 'value'`). Hardcoded values make queries less reusable and may cause silent behaviour changes as valid values grow.
- Prefer `SELECT *` over listing specific columns, unless the codebase clearly does otherwise. Reasons:
  - One query (e.g. `SELECT * FROM .. WHERE id = $1`) serves many use cases, instead of many near-duplicate queries with the same filters but different column lists.
  - No need to update the query when a column is added. (Safe during deployment too: old code using `SELECT *` just ignores columns it doesn't know about.)
  - Simpler code outweighs the extra data over the wire for most use cases. Only optimise the column list when QPS is very high.

### Translations

- The Translation SDK (`github.com/carousell/Translation/Translation/lib/translation`) prefetches all translations and stores them locally, refreshing periodically. Hence, `GetTranslationResponse()` is a local in-memory lookup, NOT a network call — there is no need to parallelize it with other RPC calls.

### Generated Mocks

Mock files generated by `mockgen` (or similar tools) must never be edited by hand.

To regenerate a mock:
1. Locate the `//go:generate mockgen ...` directive in the source file (usually in `types.go` or alongside the interface definition).
2. If the directive is incorrect, update it. If it is missing entirely, add it.
3. Run `go generate ./path/to/package` (or `go generate ./...`) to regenerate the mock.

Do NOT invoke `mockgen` directly from the shell as a one-off command. The `//go:generate` directive is the source of truth for how the mock is generated, and bypassing it leaves the directive out of sync with the generated file.

**One directive per source file:** Never have two `//go:generate mockgen` directives with the same `-source` file pointing to different `-destination` paths. This creates duplicate mocks that can diverge. Each source file should have exactly one directive generating one mock file, kept in the same package (e.g. `-destination=mock_foo.go -package=<same-package>`). Multiple directives are fine when interfaces are spread across multiple source files — since `-source` only accepts a single file, one directive per source file is the correct approach.

### Testing

See the `carousell-golang-testing` skill. Use this skill before reading or writing any `_test.go` files or any other test related code (eg. helper functions), it has code conventions and guidance on internal libraries.

## Infra

### Environments

- **Production**
- **Staging** (stable development)
- **Feature** (personal development environments)
  - Each developer can spawn as many feature envs as desired.
  - A feature env contains 1 or more backend services, typically only the services being modified.
  - Each feature env must have a unique name. ASK the user for the feature env name, don't assume.
  - Feature env services connect to the staging database. Feature env services will call staging services (when the service doesn't exist in the feature env) or other services in the same feature env.

#### Routing to a feature env: the `c-tenancy` header

**`c-tenancy: <feature-env-name>` on the incoming request is how a call reaches services in a given feature env.** Set it on the entry request; it propagates hop by hop, so every downstream call in that request's chain routes to the same feature env (falling back to staging for services absent from it).

- This is the ONLY correct mechanism. Do NOT override a dependency's host/port in config (e.g. pointing `subscriptionGrpc.hostPort` at `subscription-svc-cip.<ns>.svc.cluster.local`) to reach a feature env's copy of a service.
- Propagation is automatic for services using Orion's `ForwardMetadataInterceptor` (forwards incoming gRPC metadata to outgoing calls); `c-tenancy` is also whitelisted in `go-utils/cheaders`. Verify the interceptor is in the outbound client's chain if routing doesn't take effect.
- Without the header, calls go to **staging**. A staging service that lacks a new RPC returns `Unimplemented: unknown service <proto.Service>` -- a common symptom of a forgotten `c-tenancy`.
- How to set it: HTTP -- a `c-tenancy` request header (`curl -H 'c-tenancy: <env>'`); gRPC -- request metadata (`metadata.AppendToOutgoingContext(ctx, "c-tenancy", "<env>")`).
- Caveat when testing: results cached in redis (shared with staging) can mask whether routing worked. Vary the input so the lookup misses the cache rather than deleting keys from shared redis.

### Deployment Process

Canary deployment followed by rollout on k8s. This will mean that backwards compatibility needs to be handled, because there will a period of time when there are both old and new pods are running and serving production traffic at the same time.

## Key Business Context

Categories: refer to the `carousell-categories` skill.

## How tos

### Run or debug a service locally with mirrord

When you want to run, start, or debug a service locally (including to verify a code change or hit a handler) read `references/run-service-locally.md`.

### Check which code path runs in production

The codebase can contain dead code -- present but no longer reached, given the current flags/configs. To determine which path actually runs, check **production** config and flag values. Staging and feature env values don't always match production.
