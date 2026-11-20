---
name: carousell-golang-testing
description: CLAUDE.md for writing tests for Go code in Carousell. Use this skill before writing any _test.go files or any test related code (eg. helper functions).
---

# Carousell Golang Testing

## Conventions & Best Practices

- **Match the existing test framework**, even if it differs from these guidelines, unless it's difficult to maintain or clearly incorrect.
- **Assert all values on structs** (go-cmp, testify, built-ins -- any framework). Compare the whole struct, not cherry-picked fields, unless that needs very complex setup. Scales as fields are added; avoids missing regressions. See "Using cmp.Diff".
- **Use `t.Helper()`** (or the framework equivalent) in test helpers.
- Prefer built-ins for simple assertions; use `assert` for multiple or complex ones.
- **Mock external dependencies** (eg. API clients) with `mockgen` (`//go:generate` statements in go files). Avoid hand-written mocks/fakes; for datastores use `testinglib` (see "Choosing a level to test at").
- **Don't assert on error message strings** (e.g. `assert.Contains(t, err.Error(), ...)`) -- messages change. Only check whether an error was returned.
- **Prefer extending an existing happy-path case over adding a near-duplicate.** When the function gains a field or minor branch, fold it into an existing case. Add a new case only when the new behaviour has multiple variants worth isolating. Why: one case exercising all fields stays compact as the struct grows; per-field duplication bloats the table.

### Choosing a level to test at

**Prefer integration tests over mocking** -- for example, test a manager against a real DB via `testinglib` (see "Datastore tests"), not against a mock store. Overlapping with store-level coverage is fine: only the integration test proves the layers compose.

Scope each level to the logic it owns:

- **Manager-level:** flows and branches the manager owns -- eg. status transitions, cross-field arithmetic, what lands in the DB.
- **Store/DB-level:** DB edge cases -- CAS conflicts, unknown-column/JSON-key preservation, constraint violations, query filters, ordering. Don't re-enumerate these at the manager level.

### Choosing a test structure

- **Simple tests (pure functions, straightforward mocks/data):** strongly prefer table-driven, even if other tests in the file don't.
- **Complex integration tests (many mocks, complex conditions):** follow what's conventional for the codebase -- either table-driven with a per-case `setup` func (see below), or subtests where each case is its own `t.Run` block with inline setup.

### Table-driven tests

- Descriptive case names.
- **Single unified `setup` func per case** handling all per-case setup (DB seeding, mock config, etc). Do not split into `setupDB`/`setupMocks`, do not seed DB inside the for loop or via separate struct fields. Use helpers to cut repetition. Scalable: reading `setup` alone explains all seeding and mocks.
- **The runner loop contains only these, in order:** controller/store construction, `tt.setup(...)`, SUT construction, the call under test, the `wantErr` check, and the assertions. Anything else -- seeding, mock config, projecting or sorting a result before comparing, a nil-check, an early `return` -- belongs in a per-case func or a helper, never in the loop. If cases differ in *whether or what* calls happen (not just returned values), that axis is the `setup` func's job -- never a bool/scalar field the runner branches on. A case that makes no call has an empty `setup` body, not `expectCall: false`.
  ```go
  // WRONG: runner must branch: if tc.expectQuery { client.EXPECT().Search(...).Return(...tc.totalCount...) }
  cases := []struct{ token string; expectQuery bool; totalCount int64; want bool }{...}
  // RIGHT: mock behaviour lives in the case; runner just calls tc.setup(client), no nil-check
  cases := []struct{ token string; setup func(c *vespa.MockSearchClient); want bool }{
      {token: "a", setup: func(c *vespa.MockSearchClient) {}, want: true}, // no call
      {token: "car", setup: func(c *vespa.MockSearchClient) {
          c.EXPECT().Search(gomock.Any(), gomock.Any()).Return(&vespa.SearchResponse{TotalCount: 12}, nil)
      }, want: false},
  }
  ```
- **When the assertions have more than one axis, give the case a `post` func too.** Two datastores to read back, a projection plus a count, a value plus "how many rows" -- once the runner's assertion section is a `cmp.Diff` per return-value, move it into a per-case `post` and have the runner call `tt.post(t, ...)`. Wrap each `fetch...` + `cmp.Diff` pair in a logic-free `assert...` helper so a `post` body is one call per thing asserted. `post` is non-nullable: a case asserting nothing gets an empty literal, never `nil`, so the runner needs no branch.
  ```go
  cases := []struct{
      name    string
      setup   func(t *testing.T, c *loyalty.MockClient)
      post    func(t *testing.T, deps *testDeps)   // <- assertions live here, not in the loop
      wantErr bool
  }{...}
  ```
  Don't reach for this on a single-axis table -- one `cmp.Diff` on a `want` field in the runner is correct and simpler.
- **`setup` should not return values.** Declare test IDs as constants/vars at the top of the test function; reference them in both `setup` and assertions. Exception: if setup is so complex that hardcoding IDs is unwieldy, returning a struct is simpler. (A `post` func is the exception's exception: when setup builds mocks the assertions also need, having `setup` return a deps struct that both it and `post` share beats threading them through package vars.)
- **No branching on case name** (`if tc.name == ...`). Express per-case behavior through fields (inputs, config, setup func).
- **Use the full config struct in test cases**, not cherry-picked fields assembled later. Same for input and expected output. Use helpers to construct it.
- **Error and response assertion pattern:**
  ```go
  if tc.wantErr != (err != nil) {
      t.Fatalf("wantErr=%v, got err=%v", tc.wantErr, err)
  }
  // assert on response below
  // do NOT add `if tc.wantErr { return }` first -- we must check the correct value is returned even when wantErr is true
  ```

### Common mistakes

- `t.Cleanup(...)` runs like `defer`, so it must go at the **start** of the test, not the end. Common mistake in existing tests -- fix it when you see it.
- Don't alias named constants (e.g. enum values) just to shorten them in cases. Use the full name directly; aliases add indirection for no benefit when referenced only once or twice.
  ```go
  // NOT ok
  makeTag := pb.SomeTag_SOME_TAG_MAKE_MODEL
  wantTags: []pb.SomeTag{makeTag, priceTag}
  // OK
  wantTags: []pb.SomeTag{pb.SomeTag_SOME_TAG_MAKE_MODEL, pb.SomeTag_SOME_TAG_PRICE_RANGE}
  ```

### Panicking in test code

Panicking is more acceptable in tests than in production, and often preferable.

**OK to panic** -- fail fast on missing test infrastructure:
```go
// In a table-driven test:
// More preferable:
tt.validateFunc(t)
// Less preferable:
if tt.validateFunc != nil { tt.validateFunc(t) }
```
A missing `validateFunc` means the outcome isn't validated -- better to panic and surface it.

**Not OK to panic** -- on expected-vs-actual mismatch; panicking hides whether other cases also fail.

### Using cmp.Diff

- Use `cmp.Diff` for structs/slices/maps. For scalars use `if got != want` or `assert.Equal`.
- Prefer `cmpopts` Comparers over custom ones: `cmpopts.EquateApprox`, `EquateApproxTime`, `SortSlices`, `SortMaps`.
- For proto messages: `cmp.Diff(..., protocmp.Transform(), cmpopts.EquateEmpty())`.
- **Assert the contract, not today's output.** When the contract leaves something unspecified (slice order, map iteration, whitespace), neutralise it with a comparator (`SortSlices`, `SortMaps`) or normalise before comparing. Such a comparator is NOT dead even if the output is deterministic today -- it keeps the test green through refactors that change the unpromised property. When a reviewer (e.g. `/simplify`) flags it as removable because "the output is deterministic", keep it; drop it only if callers genuinely rely on that property.

### Datastore tests (postgres, redis, es, cass)

Use containerised datastores via `github.com/carousell/go-utils/testinglib`: `/pg`, `/redis`, `/es` (elasticsearch), `/cass` (cassandra).

- Spawning containers (`testinglib_pg.NewInstance(...).Start()`) is slow -- don't spawn one per table case. Reset between cases instead: (a) faster: `container.TruncateTables(...)`; or (b) `container.CleanupDB()` then `container.SetupDB()`.

### Adding tests to a complex, untested function

1. Don't add everything at once -- add a few critical paths (ask the user which), but structure for easy extension (e.g. include `wantErr` even if only testing happy paths). Mocks are hard to set up, so few cases are easier to debug and vet than many.
2. Test critical happy paths before error handling (assuming errors follow `if err != nil { return nil, errors.Wrap(...) }`). Confirm with the user first.
