#!/bin/bash
set -euo pipefail

# Carousell gRPC Caller Helper Script
# Usage: ./grpc-call.sh <environment> <service> <method> <request-json>

ENV="${1:-}"
SERVICE="${2:-}"
METHOD="${3:-}"
REQUEST="${4:-}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Cluster mappings
declare -A CLUSTERS=(
  ["feat"]="gke_carousell-staging_asia-east1-c_staging-feature-k127"
  ["stage"]="gke_carousell-staging_asia-east1-c_staging-main-k127"
  ["prod"]="gke_thecarousell.com:api-project-11554775814_asia-east1_main-a-k127"
)

declare -A NAMESPACES=(
  ["feat"]="default"
  ["stage"]="default"
  ["prod"]="default"
)

print_usage() {
  cat << EOF
${YELLOW}Carousell gRPC Caller${NC}

Usage: ./grpc-call.sh <environment> <service> <method> <request-json>

Environments:
  feat    Feature environment (staging-feature-k127)
  stage   Staging environment (staging-main-k127)
  prod    Production environment (thecarousell.com) - USE WITH CAUTION

Examples:
  ./grpc-call.sh stage user-svc GetUser '{"user_id":"123"}'
  ./grpc-call.sh feat listing-svc ListListings '{}'

EOF
}

error() {
  echo -e "${RED}✗ Error: $1${NC}" >&2
  exit 1
}

info() {
  echo -e "${GREEN}✓ $1${NC}"
}

warn() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

verify_grpcurl() {
  if ! command -v grpcurl &> /dev/null; then
    error "grpcurl not installed. Install with: brew install grpcurl"
  fi
  info "grpcurl found: $(grpcurl -version 2>&1 | head -1)"
}

verify_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    error "kubectl not installed"
  fi
}

validate_env() {
  if [[ ! " ${!CLUSTERS[@]} " =~ " ${ENV} " ]]; then
    error "Invalid environment: $ENV. Must be one of: ${!CLUSTERS[@]}"
  fi
}

validate_input() {
  [[ -z "$ENV" ]] && error "Environment not specified"
  [[ -z "$SERVICE" ]] && error "Service name not specified"
  [[ -z "$METHOD" ]] && error "Method name not specified"
  [[ -z "$REQUEST" ]] && error "Request JSON not specified"
}

switch_context() {
  local cluster="${CLUSTERS[$ENV]}"
  local current=$(kubectl config current-context 2>/dev/null || echo "")

  if [[ "$current" != "$cluster" ]]; then
    info "Switching to $ENV context..."
    kubectl config use-context "$cluster" > /dev/null
  fi
  info "Current context: $(kubectl config current-context)"
}

find_pod() {
  local namespace="${NAMESPACES[$ENV]}"
  local pod=$(kubectl get pods -n "$namespace" -l "app=$SERVICE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$pod" ]]; then
    error "Pod not found for service: $SERVICE in namespace: $namespace"
  fi

  echo "$pod"
}

port_forward_pod() {
  local namespace="${NAMESPACES[$ENV]}"
  local pod="$1"
  local local_port="${2:-50051}"
  local remote_port="${3:-50051}"

  # Check if port is already in use
  if lsof -i ":$local_port" > /dev/null 2>&1; then
    warn "Port $local_port already in use, attempting to use port 50052..."
    local_port=50052
  fi

  # Start port-forward in background
  kubectl port-forward -n "$namespace" "pod/$pod" "$local_port:$remote_port" > /dev/null 2>&1 &
  local pf_pid=$!

  # Give it a moment to establish
  sleep 1

  # Verify connection
  if ! grpcurl -plaintext localhost:$local_port list > /dev/null 2>&1; then
    kill $pf_pid 2>/dev/null || true
    error "Failed to establish port-forward connection"
  fi

  echo "$local_port"
}

validate_request_json() {
  if ! echo "$REQUEST" | jq . > /dev/null 2>&1; then
    error "Invalid JSON in request: $REQUEST"
  fi
}

execute_grpc_call() {
  local port="$1"

  # Construct full method name (assumes carousell.service.v1.Service/Method pattern)
  local service_name="${SERVICE%-svc}"  # Remove -svc suffix
  local full_method="carousell.${service_name}.v1.${service_name^}Service/${METHOD}"

  info "Calling: $full_method"
  info "Request: $REQUEST"

  grpcurl -plaintext \
    -d "$REQUEST" \
    "localhost:$port" \
    "$full_method"
}

cleanup() {
  # Kill any port-forward processes
  pkill -f "kubectl port-forward.*$SERVICE" 2>/dev/null || true
}

trap cleanup EXIT

# Main execution
main() {
  validate_input
  validate_env

  if [[ "$ENV" == "prod" ]]; then
    warn "PRODUCTION ENVIRONMENT - Be extremely careful!"
  fi

  verify_grpcurl
  verify_kubectl
  validate_request_json

  switch_context

  local pod=$(find_pod)
  info "Found pod: $pod"

  local port=$(port_forward_pod "$pod")
  info "Port-forward established on localhost:$port"

  # Execute the gRPC call
  execute_grpc_call "$port"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 4 ]]; then
    print_usage
    exit 1
  fi
  main
fi
