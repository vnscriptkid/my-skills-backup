---
name: db-query
description: "Run a READ-ONLY ad-hoc Postgres query against any Carousell Go service's database in GKE (stage, feature env, or prod), by writing a tiny Go program that reuses the service's own config loader for DB credentials, cross-compiling it, and running it inside a live pod. Enforces read-only at the Postgres session level, not just by asking -- Postgres itself rejects any write. Works for any service without needing psql, apt, or internet access on the pod. Usage: /db-query"
argument-hint: "[query]"
allowed-tools: Bash(kubectl *), Bash(go build *), Read, Write, Grep, Glob
---

# db-query: Run a READ-ONLY Postgres query against any service's DB, via a tiny generated Go program

You are connecting to a Carousell Go service's Postgres database to run an ad-hoc **read-only**
query (usually for debugging). This skill is for querying only -- it does not run writes, in
any environment, including staging. This is a **general** technique -- it works for any
service, not just one DB or one service, because it reuses **the service's own config-loading
code** to get real, already-resolved DB credentials (including Vault-backed secrets), rather
than trying to reconstruct them by hand or relying on a DB client being installed on the pod.

**Why not `psql` directly:** these DBs are commonly reached via Istio-mesh-routed virtual
hostnames (`kubectl get endpoints <db-svc>` comes back empty -- no selector, no real backing
pod), so `kubectl port-forward` to the DB service won't work. And the app pod's image is
usually minimal -- no `psql`, sometimes no `apt`/internet access either (especially in prod),
so installing a client on the fly isn't reliable. **Why not hand-parse the ConfigMap YAML:**
credentials are frequently `!SECRET vault/path@version` references, not plaintext -- you'd need
to reimplement Vault resolution yourself. The service's own binary already does all of this at
startup; reuse that instead of fighting it.

The general shape: **ask which service → find its config-loader function and DB config
struct → write a ~40-line throwaway `main.go` that calls that loader, opens a `database/sql`
connection with the resolved credentials, and runs the query → cross-compile it for the pod's
OS/arch → copy it in and run it → delete everything, including the temp source file.**

---

## Step 0: Resolve inputs

**Service name** -- ask the user, do not guess. Resolve its repo path (usually
`~/code/go/src/github.com/carousell/<ServiceName>`).

**Environment** -- ask which one, do not guess:
- **staging (main)** -- e.g. `gke_carousell-staging_asia-east1-c_staging-main-k127`
- **staging (feature env)** -- e.g. `gke_carousell-staging_asia-east1-c_staging-feature-k127` (ask for the feature env's namespace too, e.g. `fe-<service>-r167`)
- **production** -- ask for the exact context; do not assume one. Treat with the safety gate below.
- Or: the user gives you a specific `kubectl` context directly.

**Namespace:** usually the service name in lowercase (e.g. `user` for UserSvc), but feature
envs use their own namespace. Confirm if unsure.

**What to query:** ask the user in plain language what they want to find out, and/or the exact
SQL if they already have it. This skill only runs `SELECT`-shaped reads -- if what they actually
need is a data change, stop and say so (see Step 2); do not try to route around it.

**Which DB:** a service often has more than one DB config block (e.g. a legacy DB + its own
native DB, each with master/replica). Find these by grepping the service's config struct for
fields of a Postgres-config type (see Step 1) and ask the user which one applies, in plain
terms. Default to the **replica**, not master, unless a zero-lag read is actually needed
(master is fine to read from -- it's still read-only, just against the primary).

---

## Step 1: Find the service's config loader and DB config shape

Every Carousell Go service following this pattern has an exported `Load*Config()` function.
Find it and the Postgres config struct's field names:

```bash
grep -rn "^func Load.*Config" <service_repo>/**/config/*.go
grep -rn "PGHostPort\|PGUsername\|PGPassword\|PGDbName\|dalutils.PGConfig" <service_repo>/**/config/types.go
```

Also confirm the Postgres driver already vendored (so the generated program needs zero new
dependencies):

```bash
grep -n "lib/pq\|jackc/pgx\|jmoiron/sqlx" <service_repo>/go.mod
```

If the service doesn't follow this config-loader pattern at all, tell the user this technique
doesn't apply and stop rather than improvising something that bypasses their real config/secret
resolution.

---

## Step 2: Safety gates

**This skill is read-only, full stop -- in every environment, including staging.**
It's not a "please confirm" policy that someone under time pressure can wave through -- the
generated program itself sets `default_transaction_read_only = on` on the connection (Step 3)
before running anything, so Postgres rejects any write statement at the database level,
regardless of what query text was passed in. Do not remove or work around that line for any
reason. If the user actually needs to change data, stop and tell them to use the service's own
write path (its gRPC/HTTP API) or a proper migration -- not this tool, not even in staging.

**Production:**
If the environment is production, stop and get an explicit typed confirmation before doing
anything else (e.g. ask the user to type `PROD`). State plainly what you're about to connect to
(service, DB block, master/replica) first -- reads against prod can still surface sensitive
data, so confirm the target deliberately even though it's read-only.

---

## Step 3: Write the throwaway Go program

Create it as a new `main.go` **inside the service's own module** (e.g.
`<service_repo>/cmd/dbquery_temp/main.go`), so it can import the service's internal config
package directly. This file is scratch -- never commit it.

Shape (adapt import paths / config field names to the actual service):

```go
package main

import (
	"fmt"
	"os"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq" // or whatever driver Step 1 found

	"github.com/carousell/<Service>/<path>/config"
)

func main() {
	query := os.Args[1]

	cfg, err := config.Load<Service>Config() // the function found in Step 1
	if err != nil {
		fmt.Println("config load error:", err)
		os.Exit(1)
	}

	pg := cfg.<TheChosenDBConfigField> // e.g. cfg.DBSlaveConfig
	dsn := fmt.Sprintf("postgres://%s:%s@%s/%s?sslmode=disable",
		pg.PGUsername, pg.PGPassword, pg.PGHostPort, pg.PGDbName)

	db, err := sqlx.Connect("postgres", dsn)
	if err != nil {
		fmt.Println("connect error:", err)
		os.Exit(1)
	}
	defer db.Close()

	// Hard read-only enforcement: Postgres itself now rejects any write statement on this
	// connection, regardless of what query text is passed below. Do not remove this.
	if _, err := db.Exec("SET default_transaction_read_only = on"); err != nil {
		fmt.Println("failed to set read-only mode, refusing to proceed:", err)
		os.Exit(1)
	}

	rows, err := db.Queryx(query)
	if err != nil {
		fmt.Println("query error:", err)
		os.Exit(1)
	}
	defer rows.Close()

	cols, _ := rows.Columns()
	fmt.Println(cols)
	for rows.Next() {
		row := make(map[string]interface{})
		if err := rows.MapScan(row); err != nil {
			fmt.Println("scan error:", err)
			os.Exit(1)
		}
		fmt.Println(row)
	}
}
```

This never touches or prints the raw secret: `Load<Service>Config()` resolves `!SECRET
vault/path@version` references via Vault in-process, and the resolved value only ever exists
inside this program's memory -- unlike passing `PGPASSWORD` on a command line, nothing sensitive
appears in shell history, process listings, or logs.

---

## Step 4: Cross-compile for the pod

```bash
cd <service_repo>
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/dbquery-tmp ./cmd/dbquery_temp
```

(Adjust `GOARCH` if the cluster's nodes aren't amd64 -- check with `kubectl get nodes -o
jsonpath='{.items[0].status.nodeInfo.architecture}'` if unsure.)

---

## Step 5: Pick a pod, copy the binary in, and run it

```bash
kubectl --context <context> -n <namespace> get pods -l app=<service>
```

Pick a `Running` pod (not `CrashLoopBackOff`/`Completed`), confirm the app container's name
(commonly matches the service name), then:

```bash
kubectl --context <context> -n <namespace> cp /tmp/dbquery-tmp <pod>:/tmp/dbquery-tmp -c <container>
kubectl --context <context> -n <namespace> exec <pod> -c <container> -- chmod +x /tmp/dbquery-tmp
kubectl --context <context> -n <namespace> exec <pod> -c <container> -- /tmp/dbquery-tmp "<query>"
```

The binary must run inside the **same container** that has the service's config volume
mounted (usually the main app container) -- that's what makes `config.Load<Service>Config()`
resolve without any extra setup: it reads the exact same config file the real service reads.

---

## Step 6: Clean up -- every time, no exceptions

```bash
kubectl --context <context> -n <namespace> exec <pod> -c <container> -- rm -f /tmp/dbquery-tmp
rm -f /tmp/dbquery-tmp
rm -rf <service_repo>/cmd/dbquery_temp
```

Then `git status --short` in the service repo to confirm nothing was left behind or staged.
This is scratch debug tooling -- it must never end up in a commit.

---

## Important notes

- **This is a read-only tool, in every environment, no exceptions.** The `SET
  default_transaction_read_only = on` line in Step 3 is what makes this a real guarantee rather
  than a policy someone can talk you out of -- never remove it, never write a version of the
  script without it.
- If someone needs to change data, that's a different task: point them at the service's own
  write path or a migration, don't extend this skill to do it.
- **Never** guess a production context or namespace -- always ask.
- Default to the **replica**, not master, unless a zero-lag read is actually needed.
- If the service doesn't have a `Load*Config()`-style function or doesn't use
  `dalutils.PGConfig`-shaped fields, this technique doesn't directly apply -- say so rather than
  forcing it.
- Always clean up the temp source file, the local binary, and the in-pod binary -- every run, whether it succeeded or failed.
