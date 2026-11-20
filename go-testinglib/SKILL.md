---
name: go-testinglib
description: Write Go integration tests using github.com/carousell/go-utils/testinglib. Use when writing integration tests that need real Postgres or Redis instances via Docker containers in Go projects at Carousell.
---

# Go Integration Tests with testinglib

Guide for writing integration tests using `github.com/carousell/go-utils/testinglib` — a Docker-based test infrastructure library used in Carousell Go services.

---

## Package Overview

```
github.com/carousell/go-utils/testinglib        # Core: options, base types
github.com/carousell/go-utils/testinglib/pg     # Postgres container
github.com/carousell/go-utils/testinglib/redis  # Redis container
```

---

## Standard Test File Structure

Integration tests live in a dedicated package, typically `integrationtests/` or similar, and use `TestMain` to spin up containers once for all tests.

```
service/integrationtests/
  main_test.go        # TestMain: start containers, init deps, run suite
  foo_test.go         # Individual test files
  bar_test.go
```

---

## TestMain Pattern (main_test.go)

```go
package integrationtests

import (
    "log"
    "os"
    "path/filepath"
    "testing"

    "github.com/carousell/go-utils/testinglib"
    testinglibpg    "github.com/carousell/go-utils/testinglib/pg"
    testinglibRedis "github.com/carousell/go-utils/testinglib/redis"
)

var (
    pgContainer   testinglibpg.TestingPG
    redisInstance testinglibRedis.TestingRedis
    // your initialized service/repo clients go here
)

func TestMain(m *testing.M) {
    // Migration path MUST be absolute
    migrationDir, err := filepath.Abs("../../migration/pg/")
    if err != nil {
        log.Fatal(err)
    }

    // Start Postgres
    pgContainer = testinglibpg.NewInstance("14", testinglib.WithMigrationPath(migrationDir))
    if err := pgContainer.Start(); err != nil {
        log.Fatal(err)
    }
    defer pgContainer.Stop()

    // Start Redis (optional)
    redisInstance = testinglibRedis.NewInstance("6.0")
    if err := redisInstance.Start(); err != nil {
        log.Fatal(err)
    }
    defer redisInstance.Stop()

    // Run migrations
    if err := pgContainer.SetupDB(getDB()); err != nil {
        log.Fatal(err)
    }

    // Initialize your service/repo clients using container config
    pgCfg := pgContainer.GetConfig()
    // pgCfg.Host, pgCfg.Port, pgCfg.UserName, pgCfg.Password, pgCfg.DBName

    // ... build your clients here ...

    code := m.Run()
    os.Exit(code)
}

func cleanup(t *testing.T) {
    t.Helper()
    if err := pgContainer.TruncateTables(getDB(), []string{
        "table_one",
        "table_two",
    }); err != nil {
        t.Fatal(err)
    }
    // For Redis: redisInstance.Cleanup()
}
```

---

## Postgres Container API

### Creating an Instance

```go
pg := testinglibpg.NewInstance(
    "14",                                           // Postgres version tag
    testinglib.WithMigrationPath(absPath),          // abs path to .up.sql files
    testinglib.WithMaxRetrySec(30),                 // optional: increase retry wait
)
```

Default credentials (auto-configured, read via `GetConfig()`):
- User: `postgres`, Password: `secret`, DB: `postgres`

### TestingPG Interface

```go
type TestingPG interface {
    Start() error
    Stop()
    GetConfig() Config                                    // Host, Port, UserName, Password, DBName
    SetupDB(execer Execer) error                         // runs all *.up.sql in migration dir
    CleanupDB(execer Execer) error                       // runs all *.down.sql in reverse order
    TruncateTables(txer TransactionStarter, tables []string) error
}
```

### Getting the Config

```go
cfg := pgContainer.GetConfig()
// cfg.Host     string
// cfg.Port     string  (note: string, not int)
// cfg.UserName string
// cfg.Password string
// cfg.DBName   string
```

### Migrations

`SetupDB` runs all `*.up.sql` files in the migration directory in alphabetical order.
`CleanupDB` runs all `*.down.sql` files in reverse alphabetical order.
Migration directory **must be an absolute path**.

---

## Redis Container API

### Creating an Instance

```go
redis := testinglibRedis.NewInstance("6.0") // Redis version tag
```

### TestingRedis Interface

```go
type TestingRedis interface {
    Start() error
    Stop()
    GetHost() string    // IP of the container
    GetPort() string    // mapped port
    Cleanup()           // FLUSHALL — use between tests to clear state
}
```

### Connecting to Redis Container

```go
redisAddr := redisInstance.GetHost() + ":" + redisInstance.GetPort()
// e.g. "127.0.0.1:49321"
```

---

## Writing Individual Tests

### Table Cleanup Between Tests

Use `defer cleanup(t)` at the start of each test (or subtest) to reset state:

```go
func TestCreateFoo(t *testing.T) {
    defer cleanup(t)

    // ... test body ...
}
```

### Per-Test Resource Cleanup (t.Cleanup)

For resources allocated inside a test, use `t.Cleanup`:

```go
func TestSomething(t *testing.T) {
    container := startSomething(t)
    t.Cleanup(func() { container.Stop() })
    // ...
}
```

### Subtests with Shared Setup

```go
func TestFoo(t *testing.T) {
    t.Run("case one", func(t *testing.T) {
        defer cleanup(t)
        // seed data, run, assert
    })

    t.Run("case two", func(t *testing.T) {
        defer cleanup(t)
        // different scenario
    })
}
```

---

## Complete Example

```go
package integrationtests

import (
    "context"
    "log"
    "os"
    "path/filepath"
    "testing"

    "github.com/carousell/go-utils/testinglib"
    testinglibpg "github.com/carousell/go-utils/testinglib/pg"
    "github.com/stretchr/testify/assert"

    "github.com/example/myservice/dal"
)

var (
    pgContainer testinglibpg.TestingPG
    repo        *dal.Repository
)

func TestMain(m *testing.M) {
    migrationDir, _ := filepath.Abs("../../migration/pg/")

    pgContainer = testinglibpg.NewInstance("14", testinglib.WithMigrationPath(migrationDir))
    if err := pgContainer.Start(); err != nil {
        log.Fatal(err)
    }
    defer pgContainer.Stop()

    cfg := pgContainer.GetConfig()
    db, err := dal.OpenPostgres(cfg.Host, cfg.Port, cfg.UserName, cfg.Password, cfg.DBName)
    if err != nil {
        log.Fatal(err)
    }

    if err := pgContainer.SetupDB(db); err != nil {
        log.Fatal(err)
    }

    repo = dal.NewRepository(db)

    os.Exit(m.Run())
}

func cleanup(t *testing.T) {
    t.Helper()
    err := pgContainer.TruncateTables(repo.GetDB(), []string{"items", "orders"})
    if err != nil {
        t.Fatal(err)
    }
}

func TestGetItem(t *testing.T) {
    t.Run("returns item by id", func(t *testing.T) {
        defer cleanup(t)

        // seed
        ctx := context.Background()
        created, err := repo.CreateItem(ctx, &dal.Item{Name: "apple", Price: 100})
        assert.NoError(t, err)

        // act
        got, err := repo.GetItem(ctx, created.ID)

        // assert
        assert.NoError(t, err)
        assert.Equal(t, "apple", got.Name)
    })

    t.Run("returns error when not found", func(t *testing.T) {
        defer cleanup(t)

        _, err := repo.GetItem(context.Background(), 99999)

        assert.Error(t, err)
    })
}
```

---

## Key Rules

- Migration path passed to `WithMigrationPath` must be **absolute** — use `filepath.Abs()`.
- `Start()` blocks until the container is ready (health-checked via TCP connection).
- Call `pgContainer.SetupDB(db)` **once** after `Start()` to apply migrations.
- Use `TruncateTables` between tests, not `CleanupDB` (which runs `.down.sql` teardown migrations).
- `TestingPG.GetConfig().Port` is a `string`, not an `int` — convert with `strconv.Atoi` if your driver requires an integer.
- The `Execer` passed to `SetupDB`/`CleanupDB` must implement `Exec(query string, args ...interface{}) (sql.Result, error)` — `*sql.DB` satisfies this.
- The `TransactionStarter` passed to `TruncateTables` must implement `Begin() (*sql.Tx, error)` — `*sql.DB` satisfies this.
- Both `*sql.DB` from `database/sql` and `sqlx.DB` from `jmoiron/sqlx` satisfy both interfaces.

---

## Build Tags

Integration tests should not run during unit test passes. Use a build tag:

```go
//go:build integration
// +build integration

package integrationtests
```

Run with: `go test -tags=integration ./integrationtests/...`

Or if no build tag is used (common in this repo), put tests in a separate directory and run them explicitly.

---

## go.mod Dependencies

```
require (
    github.com/carousell/go-utils/testinglib       v1.0.4
    github.com/carousell/go-utils/testinglib/pg    v0.7.3
    github.com/carousell/go-utils/testinglib/redis v0.7.3
)
```

Check the current repo's `go.mod` for the pinned versions.
