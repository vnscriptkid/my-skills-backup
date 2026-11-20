# Carousell Golang Metrics

Metrics here = prometheus metrics.

**Why they exist:** live insight into the health of a flow or API. For business-critical flows, metrics feed victorops alerts (often week-over-week) so you are told about a problem proactively, instead of waiting for bug reports. Example: WoW alerts on ad fill rate, ad impression volume, and ad click volume, each partitioned by ad source, ad type, platform, and country.

## Before you add a metric

**Do NOT re-instrument what the framework already gives you for free:**

- gRPC endpoint error rate + latency (per RPC)
- hystrix command error rate + latency (per command)

If your goal is "is this RPC failing / slow?" or "is this downstream call failing / slow?", the metric already exists -- go query it, don't add one. Add a custom metric only for things these don't capture: business/domain events (ads served, reservations made), internal outcomes (cache hit/miss, dropped messages), or a flow that spans multiple RPCs.

## Design the metric to be alertable

Alertability is the point, not an afterthought. Before writing code, answer: **"what alert will read this metric, and does the metric let it distinguish healthy from broken?"**

1. **Pick the type by the question:**
   - **Counter** -- volume / rate of events ("how many ads served", "how many failures"). Alert on `rate()` / week-over-week. Default choice; survives restarts. Name ends in `_total`.
   - **Gauge** -- a current level that goes up and down ("queue depth", "in-flight"). Rare for alerting on a flow.
   - **Histogram** -- a distribution ("latency", "batch size"). Only if you need percentiles AND it isn't already covered by built-in gRPC/hystrix latency.

2. **Count outcomes, not just successes.** A bare `things_done_total` cannot tell "traffic dropped" from "traffic fine but we now silently do nothing". Add a `result` / `status` label (e.g. `served` / `empty` / `error`) or a separate outcome counter, so the alert can catch silent failure -- the failure mode bug reports miss.

3. **Choose labels that let the alert slice the way the team cares**, and no finer. For ad-style metrics that means source / ad type / platform / country. Every label combination is a separate time series.

4. **Never use unbounded / high-cardinality values as labels:** user IDs, listing IDs, request IDs, raw `err.Error()` strings, timestamps, CCIDs. These explode the series count and can OOM the scrape target. Labels must be a small, bounded set of known values (a fixed enum of reasons, not arbitrary strings).

## Where the code goes

First confirm the flow actually exists and find where its outcome is decided -- don't design labels for a flow whose real shape (or existence) you haven't verified. A generically-named service may not do what its name suggests.

- **One `metrics.go` per package**, in the package that owns the flow being instrumented. Instrument at the single boundary where the outcome is known (e.g. where the handler returns its final result), so each event is counted once -- not per inner helper (double counting).
- Metrics registered with the default prometheus registry are exposed automatically by the Orion framework at `/metrics`. Do NOT add a `/metrics` handler or touch server startup wiring.

**If the service already has metrics:** match its existing patterns (file layout, namespace, register style, exported-var vs helper). Consistency beats the template.

**If the service has no metrics yet:** follow `references/metrics-template.md` -- a copy-paste `metrics.go` starting point with the house conventions (namespace, `report*` helper pattern, `init()` registration, naming, histogram buckets).

## Common mistakes

| Mistake | Fix |
|---|---|
| Adding a metric for RPC / downstream error rate or latency | Already built in (gRPC / hystrix). Query the existing metric. |
| Only counting successes | Add a `result`/`status` label or an outcome counter so alerts catch silent failure. |
| A `defer` that tags every error path as `error` | Many flows return business rejections (duplicate, invalid input) as a Go `error`. Reclassify those to their own `result` value before returning, or the outcome label is useless. |
| High-cardinality label (IDs, error strings) | Use a small bounded enum. Never raw user input or IDs. |
| Instrumenting per inner helper | Instrument once at the outcome boundary to avoid double counting. |
| Gauge for an event count | Use a counter (`_total`); it survives restarts and alerts on `rate()`. |
| Treating the alert as separate work | The alert rule (PromQL in the monitoring repo) is what makes this proactive. Design the labels for it up front. |
