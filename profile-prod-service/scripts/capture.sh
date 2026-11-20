#!/usr/bin/env bash
# Capture pprof + /metrics from prod pods of an Orion (Go) service.
# Usage: bash capture.sh <app-label> [pod]
#   no pod: captures the oldest AND the youngest Running pod, one after the other
# Env: CONTEXT (default: first of prod main-a/main-b with running pods), NS (default: found via app label),
#      SECONDS_CPU (20), REMOTE_PORT (default: container port named "metrics", else 9284), LOCAL_PORT (19284), OUT (~/Downloads/<app>-pprof-<date>)
set -u
APP=${1:?app label, e.g. cats or listing-svc}
POD_ARG=${2:-}
SECONDS_CPU=${SECONDS_CPU:-20}
REMOTE_PORT_IN=${REMOTE_PORT:-}
LOCAL_PORT=${LOCAL_PORT:-19284}
OUT=${OUT:-$HOME/Downloads/$APP-pprof-$(date +%F)}
PROD_CONTEXTS="gke_thecarousell.com:api-project-11554775814_asia-east1_main-a-k127 gke_thecarousell.com:api-project-11554775814_asia-east1_main-b-k127"
NS_IN=${NS:-}
PF_PID=""
FAILED=0

k() { kubectl --context "$CONTEXT" -n "$NS" --request-timeout=20s "$@"; }

running_pods() { # oldest first
  local pods
  pods=$(k get pods -l app="$APP" --field-selector=status.phase=Running \
    --sort-by=.status.startTime -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  [ -z "$pods" ] && pods=$(k get pods --field-selector=status.phase=Running --sort-by=.status.startTime \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E "^$APP-[a-z0-9]+-[a-z0-9]+$")
  echo "$pods"
}

FOUND=""
for c in ${CONTEXT:-$PROD_CONTEXTS}; do
  CONTEXT=$c
  NS=$NS_IN
  [ -z "$NS" ] && NS=$(kubectl --context "$c" --request-timeout=20s get pods -A -l app="$APP" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
  [ -z "$NS" ] && NS=$APP
  [ -n "$(running_pods)" ] && { FOUND=1; break; }
done
[ -z "$FOUND" ] && { echo "no running pods with app=$APP on prod main-a/main-b; look up the app label + namespace with read-service-config, then set NS" >&2; exit 1; }
echo "context=$CONTEXT ns=$NS app=$APP"

stop_forward() { [ -n "$PF_PID" ] && { kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; }; PF_PID=""; }
trap stop_forward EXIT

start_forward() {
  stop_forward
  REMOTE_PORT=$(pprof_port)
  kubectl --context "$CONTEXT" -n "$NS" port-forward "pod/$POD" "$LOCAL_PORT:$REMOTE_PORT" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -m 2 -o /dev/null "http://localhost:$LOCAL_PORT/debug/pprof/" && return 0
    sleep 1
  done
  return 1
}

fetch() { # file path max_time
  curl -sS -f -m "$3" -o "$DIR/$1" "http://localhost:$LOCAL_PORT$2"
}

pprof_port() { # Orion serves pprof on the container port named "metrics" (9284 by default)
  local p
  p=$(k get pod "$POD" -o jsonpath='{.spec.containers[*].ports[?(@.name=="metrics")].containerPort}' 2>/dev/null | awk '{print $1}')
  echo "${REMOTE_PORT_IN:-${p:-9284}}"
}

capture_all() { # $1 role
  DIR=$OUT/$POD
  mkdir -p "$DIR"
  { echo "role=$1 context=$CONTEXT ns=$NS pprof_port=$REMOTE_PORT"
    k get pod "$POD" -o jsonpath='start={.status.startTime}{"\n"}{range .spec.containers[*]}{.name} image={.image} req={.resources.requests} lim={.resources.limits}{"\n"}{end}'
    kubectl --context "$CONTEXT" -n "$NS" top pod "$POD" --containers 2>/dev/null; } > "$DIR/pod.txt"
  fetch heap.pb.gz /debug/pprof/heap 30 &&
  fetch allocs.pb.gz /debug/pprof/allocs 30 &&
  fetch goroutine.txt '/debug/pprof/goroutine?debug=1' 30 &&
  fetch goroutine-full.txt '/debug/pprof/goroutine?debug=2' 60 &&
  fetch cpu.pb.gz "/debug/pprof/profile?seconds=$SECONDS_CPU" $((SECONDS_CPU + 30)) &&
  { curl -sS -f -m 60 "http://localhost:$LOCAL_PORT/metrics" | gzip > "$DIR/metrics.txt.gz"; }
}

capture_pod() { # $1 pod, $2 role (oldest|youngest) used to pick a replacement
  POD=$1
  for attempt in 1 2 3; do
    if [ "$(k get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ]; then
      if [ "$2" = youngest ]; then POD=$(running_pods | tail -1); else POD=$(running_pods | head -1); fi
      [ -z "$POD" ] && break
    fi
    echo "[$2] attempt $attempt: pod=$POD"
    if start_forward && capture_all "$2"; then
      stop_forward
      echo "saved: $OUT/$POD"; sed 's/^/  /' "$OUT/$POD/pod.txt"
      return 0
    fi
    echo "[$2] capture failed on $POD (forward dropped or pod gone); re-forwarding" >&2
  done
  stop_forward
  echo "[$2] gave up" >&2
  FAILED=1
}

if [ -n "$POD_ARG" ]; then
  capture_pod "$POD_ARG" oldest
else
  OLDEST=$(running_pods | head -1)
  YOUNGEST=$(running_pods | tail -1)
  capture_pod "$OLDEST" oldest
  [ "$YOUNGEST" != "$OLDEST" ] && capture_pod "$YOUNGEST" youngest
fi
exit $FAILED
