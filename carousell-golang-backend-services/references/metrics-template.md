# Carousell metrics.go conventions (template)

Use this only when the service has **no existing metrics**. If it already has some, copy its patterns instead.

This is the house pattern seen across Carousell Go services (e.g. `Cats`): one `metrics.go` per package, unexported collector vars, a `report*` helper per metric, registered in `init()`.

## Template

```go
package myflow

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Namespace = service name (snake_case), shared across the service.
// Real services keep this in a constants package, e.g. constants.PromMetricNamespace.
const (
	namespace = "myservice"
	subsystem = "myflow" // the flow/area this file instruments
)

var (
	// Counter: volume of an event, sliced by outcome + business dimensions.
	// Name ends in _total. Labels are a small bounded set.
	requestsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Namespace: namespace,
		Subsystem: subsystem,
		Name:      "requests_total",
		Help:      "Total myflow requests by result.",
	}, []string{"result", "country"}) // result: served/empty/error

	// Histogram: only if latency/size isn't already covered by built-in gRPC/hystrix.
	// Latency buckets in milliseconds; tune to the flow's real range.
	durationMs = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: namespace,
		Subsystem: subsystem,
		Name:      "duration_ms",
		Help:      "Latency of myflow in milliseconds.",
		Buckets:   []float64{2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048},
	}, []string{"result"})
)

// init registers every collector. Metrics are then auto-exposed at /metrics by Orion.
func init() {
	prometheus.MustRegister(requestsTotal)
	prometheus.MustRegister(durationMs)
}

// report* helpers are the ONLY place label values are supplied.
// Callers can't get the label order/count wrong, and the label contract lives here.
func reportRequest(result, country string) {
	requestsTotal.WithLabelValues(result, country).Inc()
}

func reportDuration(d time.Duration, result string) {
	durationMs.WithLabelValues(result).Observe(float64(d.Milliseconds()))
}
```

Call at the outcome boundary (once per event):

```go
func (s *Service) Handle(ctx context.Context, req *Req) (resp *Resp, err error) {
	start := time.Now()
	result := "served"
	defer func() {
		// Only default to "error" if no branch classified the outcome.
		// Business rejections (below) set result themselves.
		if err != nil && result == "served" {
			result = "error"
		}
		reportRequest(result, req.Country)
		reportDuration(time.Since(start), result)
	}()

	// Set result on every meaningful branch BEFORE returning, e.g.:
	//   if len(ads) == 0 { result = "empty"; return ... }
	// If the flow returns a business rejection (duplicate, invalid input) as a
	// Go error, classify it explicitly (result = "duplicate") -- otherwise the
	// defer tags it "error" and the outcome label can't tell rejections from real failures.
}
```

## Conventions summary

- **File:** `metrics.go` in the instrumented package.
- **Vars:** unexported (`requestsTotal`, not `RequestsTotal`). Export only if another package must record the same metric.
- **Naming:** the exposed metric is `namespace_subsystem_name` concatenated, all `snake_case`. Counters end in `_total`; the `_total` goes in the `Name` field. When the subsystem already carries the noun, `Name` is just the remainder -- e.g. `Subsystem: "add_vehicle"`, `Name: "total"` exposes `myservice_add_vehicle_total`. A bare `Name: "total"` looks wrong but is correct. Include the unit for histograms (`_ms`, `_seconds`, `_bytes`).
- **Namespace:** the service name. Prefer a shared constant if the service has one (e.g. `constants.PromMetricNamespace`) over re-declaring per file.
- **Register:** `prometheus.MustRegister(...)` in `init()`.
- **Helpers:** one `report*` func per metric; the single place `WithLabelValues` is called.
- **Help text:** always set a `Help` string; it documents the metric in Grafana.

## Variant: register helper (avoids double-registration panics)

`prometheus.MustRegister` panics if the same metric is registered twice (e.g. a package imported by multiple entry points, or in tests). Some services wrap registration to return the already-registered collector instead of panicking:

```go
func promRegisterCounterVec(c *prometheus.CounterVec) *prometheus.CounterVec {
	if err := prometheus.Register(c); err != nil {
		if are, ok := err.(prometheus.AlreadyRegisteredError); ok {
			return are.ExistingCollector.(*prometheus.CounterVec)
		}
		panic(err)
	}
	return c
}
```

Used as `requestsTotal = promRegisterCounterVec(requestsTotal)`. Only reach for this if double-registration is a real risk in the service; otherwise plain `MustRegister` in `init()` is simpler.
