---
name: profile-prod-service
description: Use when asked to profile a Carousell Go (Orion) service on prod, read its pprof, or find memory, CPU, GC or allocation optimisations; or when a service shows high CPU, heap growth, OOMs, heavy GC or a huge /metrics payload. Triggers on "/profile-prod-service", "pprof for <svc>", "port-forward pprof", "why is <svc> using so much memory/CPU".
argument-hint: "<app-label> [pod]"
---

# Profile a prod Go service

Orion serves `net/http/pprof` and `/metrics` on the container port named `metrics` (`orion.PprofPort`, 9284 by default; e.g. subscription-svc uses 9584). The script reads it from the pod spec. Capture short profiles from an old pod and a fresh pod, read the standard views, then prove each finding in code with a measured cost. **Read-only on prod:** no `exec`, no restarts, no config changes.

## 1. Capture

```bash
bash ~/.claude/skills/profile-prod-service/scripts/capture.sh <app-label> [pod]
```

- `<app-label>` is the pod's `app` label (`cats`, `listing-svc`). The script finds the namespace and the prod cluster (`main-a-k127` or `main-b-k127`; neither name contains "prod"). If it finds no pods, get the label and namespace from **read-service-config** and pass `NS=`.
- With no pod given, it captures the **oldest** pod (steady-state request cost) and then the **youngest** (startup cost and growth baseline). Per pod it saves heap, allocs, goroutines (`debug=1` and `debug=2`), a 20s CPU profile, `/metrics` and `pod.txt` (role, image, requests and limits, `kubectl top`).
- It forwards to local **19284** so it never clashes with a k9s forward on 9284. If the forward drops or the pod disappears, it re-forwards to the same pod or a replacement (3 tries), and kills the forward on exit. Run one capture at a time, or set `LOCAL_PORT`.
- Overrides: `CONTEXT`, `NS`, `SECONDS_CPU`, `OUT` (default `~/Downloads/<app>-pprof-<date>/`). Run it with `run_in_background` and wait for the notification.

## 2. Read

```bash
bash ~/.claude/skills/profile-prod-service/scripts/analyze.sh <OUT>/<pod> 'carousell/<Repo>'
go tool pprof -top -sample_index=inuse_space -diff_base=<OUT>/<young>/heap.pb.gz <OUT>/<old>/heap.pb.gz
```

For line-level listings, use the source of the deployed build. An image `.../<system>/prod:rNNN` corresponds to the git tag `images/<system>/prod/rNNN`; drop any suffix (`r59-code` → `r59`), and if the tag is still missing, use `git ls-remote --tags origin | grep rNNN`. Fetch the tag and extract it without touching the working tree, then list:

```bash
git fetch --no-tags origin tag images/<system>/prod/rNNN && mkdir -p <OUT>/src && git archive images/<system>/prod/rNNN | tar -x -C <OUT>/src
go tool pprof -trim_path=/go/src/github.com/carousell/<Repo> -source_path=<OUT>/src -list '<func>' cpu.pb.gz
```

| Signal | Meaning |
|---|---|
| `gcBgMarkWorker` + `mallocgc` > ~20% of CPU | Allocation cuts are CPU cuts, so rank by `alloc_space` |
| One function dominates allocs/CPU on the request path | Possibly per-candidate work, not per-result: run the ratio in §3 |
| Same constructor under several `factories.(*x).NewService` in in-use heap | Built N times in one binary; share one instance |
| In-use heap equal on fresh and old pods | Loaded at startup; only a problem if duplicated |
| In-use heap grows from fresh to old pod (often `prometheus.(*metricMap)`) | Leak, or metric label cardinality |
| One metric family ≫ the rest; a label with 100+ values | Unbounded label (page, id, query): bucket it or drop it |
| `hystrix.(*StreamHandler).loop`, `Timing.Percentile` or `promhttp` in CPU/allocs | Background cost. Orion always runs the hystrix event stream (JSON per circuit breaker every second, no subscriber needed); scrape cost scales with series count |
| `categorylib/category.loadData` in allocs | Periodic re-download and re-parse of all category files; check the service's refresh rate |
| Stack ends at `hystrix.GoC`/`DoC` with no service frame | Hystrix ran the closure on another goroutine, so the caller is lost. Grep the callers of the leaf; fresh vs old in-use tells startup from per-request |
| `proto.Clone` or `json.Unmarshal` of config or cache blobs per request | Skip the copy on read-only paths; cache the decoded value |
| Goroutine count higher on old pod, or one `created by` dominates | Leak, or duplicate clients per factory |

## 3. Attempts vs outcomes (find wasted work)

1. In `allocs.pb.gz`, run `-sample_index=alloc_objects -list <fn>` on the suspect function. Pick a line in that function with its own (flat) allocation that happens once per call, such as a `&T{...}` literal. Its count is roughly the number of calls since the process started. It's a sampled estimate, but good enough for ratios far above 1.
2. Find the counter that this function or its caller increments on the success branch. Sum it from the same pod's `metrics.txt.gz`; it also counts from pod start.
3. A ratio far above 1 means the work runs before the decision that discards it. For example, 162M fill attempts against 2.84M served ads means URLs were signed before the slot accepted them.

## 4. Report

1. One sentence on the biggest win.
2. Table: `# | Problem (file:line link) | Cost (% CPU / % allocs / MB) | Fix | Effort XS–M`.
3. What's fine: goroutines and heap on the fresh vs old pod, heap vs limit, CPU vs limit from `pod.txt`.
4. Where the files are saved, and that nothing was changed.

Save the headline numbers to memory.

## Common mistakes

- **60s CPU profiles.** An HPA scale-down kills the pod mid-capture and you get nothing. Keep them at 30s or under.
- **Trusting CPU %s on a quiet pod.** Under ~3s of samples, CPU shares are noise; rank by `alloc_space` since pod start instead.
- **Request-path cost from the fresh pod.** On a young pod, cumulative allocs are dominated by startup loading.
- **Listing a % without reading the code.** Confirm the mechanism, not just the hot frame.
- **Optimising the hot leaf** (`url.escape`, `hmac`) when the caller makes 50× too many calls. Fix the call count first.
- **`git checkout` of the release tag.** It clobbers a dirty branch; use `git archive`.
- **Writing captures to the scratchpad.** It gets wiped within days; keep the default `~/Downloads`.
