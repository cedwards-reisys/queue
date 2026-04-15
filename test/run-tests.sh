#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Automated test runner for ActiveMQ Classic → Artemis migration
#
# Tests three configurations:
#   1. Monolith (OpenWire, Java 8) → Classic broker
#   2. Monolith (OpenWire, Java 8) → Artemis broker
#   3. Microservice (native client, Java 21) → Artemis broker
#
# Usage:
#   ./run-tests.sh              # Run all tests
#   ./run-tests.sh --build      # Force rebuild images
#   ./run-tests.sh --quick      # Skip large message tests
#   ./run-tests.sh --k6         # Also run k6 load tests
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_FILE="$RESULTS_DIR/run-${TIMESTAMP}.txt"

BUILD_FLAG=""
QUICK_MODE=false
RUN_K6=false
PASSED=0
FAILED=0
ERRORS=()

for arg in "$@"; do
  case $arg in
    --build) BUILD_FLAG="--build" ;;
    --quick) QUICK_MODE=true ;;
    --k6)    RUN_K6=true ;;
  esac
done

# Colors (for terminal)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Log to both terminal (colored) and results file (plain)
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; echo "[$(date +%H:%M:%S)] $*" >> "$RESULTS_FILE"; }
pass() { echo -e "${GREEN}  PASS${NC} $*"; echo "  PASS $*" >> "$RESULTS_FILE"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}  FAIL${NC} $*"; echo "  FAIL $*" >> "$RESULTS_FILE"; FAILED=$((FAILED + 1)); ERRORS+=("$*"); }
warn() { echo -e "${YELLOW}  WARN${NC} $*"; echo "  WARN $*" >> "$RESULTS_FILE"; }

echo "Test run: $(date)" > "$RESULTS_FILE"
echo "==========================================" >> "$RESULTS_FILE"

# ----------------------------------------------------------
# Wait for a service to be reachable
# ----------------------------------------------------------
wait_for_http() {
  local name=$1 url=$2 max_wait=${3:-120}
  log "Waiting for $name ($url) ..."
  local elapsed=0
  while ! curl -sf "$url" > /dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge "$max_wait" ]; then
      fail "$name did not become healthy within ${max_wait}s"
      return 1
    fi
  done
  log "$name is healthy (${elapsed}s)"
}

wait_for_tcp() {
  local name=$1 host=$2 port=$3 max_wait=${4:-120}
  log "Waiting for $name ($host:$port) ..."
  local elapsed=0
  while ! bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge "$max_wait" ]; then
      fail "$name did not become healthy within ${max_wait}s"
      return 1
    fi
  done
  log "$name is healthy (${elapsed}s)"
}

# ----------------------------------------------------------
# Run a test endpoint and parse results
# ----------------------------------------------------------
run_test() {
  local label=$1 url=$2
  log "Running: $label"

  local response
  response=$(curl -sf -X POST "$url" -H "Content-Type: application/json" 2>&1) || {
    fail "$label - HTTP request failed"
    return
  }

  # Check if response is an array or single object
  local is_array
  is_array=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print('array' if isinstance(d,list) else 'object')" 2>/dev/null || echo "unknown")

  if [ "$is_array" = "array" ]; then
    local count
    count=$(echo "$response" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    for i in $(seq 0 $((count - 1))); do
      local name passed details error
      name=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i].get('testName','unknown'))")
      passed=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i].get('passed',False))")
      details=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i].get('details',''))")
      error=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i].get('error','') or '')")

      if [ "$passed" = "True" ]; then
        pass "$label / $name - $details"
      else
        fail "$label / $name - $error ($details)"
      fi
    done
  elif [ "$is_array" = "object" ]; then
    local name passed details error
    name=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('testName','unknown'))")
    passed=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('passed',False))")
    details=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('details',''))")
    error=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error','') or '')")

    if [ "$passed" = "True" ]; then
      pass "$label / $name - $details"
    else
      fail "$label / $name - $error ($details)"
    fi
  else
    warn "$label - Could not parse response"
    echo "$response" | head -5
  fi
}

# ----------------------------------------------------------
# Main
# ----------------------------------------------------------
echo ""
echo "=============================================="
echo "  ActiveMQ Migration Test Suite"
echo "=============================================="
echo ""

# Start infrastructure
log "Starting brokers and test apps..."
docker compose up -d $BUILD_FLAG 2>&1 | tail -5

# Wait for all services
wait_for_tcp  "Classic Broker (KahaDB)"  "localhost" 61616 120
wait_for_tcp  "Classic Broker (JDBC)"    "localhost" 61618 120
wait_for_tcp  "Artemis Broker"           "localhost" 61617 120
wait_for_http "Monolith → Classic"       "http://localhost:8081/test/health" 120
wait_for_http "Monolith → Classic JDBC"  "http://localhost:8084/test/health" 120
wait_for_http "Monolith → Artemis"       "http://localhost:8083/test/health" 120
wait_for_http "Microservice → Artemis"   "http://localhost:8082/test/health" 120

echo ""
echo "=============================================="
echo "  Test Suite 1: Monolith → Classic KahaDB (baseline)"
echo "=============================================="
echo ""

run_test "monolith-classic / small-message"       "http://localhost:8081/test/small-message"
run_test "monolith-classic / transaction-commit"   "http://localhost:8081/test/transaction-commit"
run_test "monolith-classic / transaction-rollback" "http://localhost:8081/test/transaction-rollback"
run_test "monolith-classic / request-reply"        "http://localhost:8081/test/request-reply"
run_test "monolith-classic / prefetch"             "http://localhost:8081/test/prefetch?count=50&sizeKb=10"

if [ "$QUICK_MODE" = false ]; then
  run_test "monolith-classic / large-message"      "http://localhost:8081/test/large-message"
fi

echo ""
echo "=============================================="
echo "  Test Suite 2: Monolith → Classic JDBC/PostgreSQL"
echo "=============================================="
echo ""

run_test "monolith-classic-jdbc / small-message"       "http://localhost:8084/test/small-message"
run_test "monolith-classic-jdbc / transaction-commit"   "http://localhost:8084/test/transaction-commit"
run_test "monolith-classic-jdbc / transaction-rollback" "http://localhost:8084/test/transaction-rollback"
run_test "monolith-classic-jdbc / request-reply"        "http://localhost:8084/test/request-reply"
run_test "monolith-classic-jdbc / prefetch"             "http://localhost:8084/test/prefetch?count=50&sizeKb=10"

if [ "$QUICK_MODE" = false ]; then
  run_test "monolith-classic-jdbc / large-message"      "http://localhost:8084/test/large-message"
fi

echo ""
echo "=============================================="
echo "  Test Suite 3: Monolith → Artemis (OpenWire)"
echo "=============================================="
echo ""

run_test "monolith-artemis / small-message"       "http://localhost:8083/test/small-message"
run_test "monolith-artemis / transaction-commit"   "http://localhost:8083/test/transaction-commit"
run_test "monolith-artemis / transaction-rollback" "http://localhost:8083/test/transaction-rollback"
run_test "monolith-artemis / request-reply"        "http://localhost:8083/test/request-reply"
run_test "monolith-artemis / prefetch"             "http://localhost:8083/test/prefetch?count=50&sizeKb=10"

if [ "$QUICK_MODE" = false ]; then
  run_test "monolith-artemis / large-message"      "http://localhost:8083/test/large-message"
fi

echo ""
echo "=============================================="
echo "  Test Suite 4: Microservice → Artemis (native)"
echo "=============================================="
echo ""

run_test "microservice-artemis / small-message"       "http://localhost:8082/test/small-message"
run_test "microservice-artemis / transaction-commit"   "http://localhost:8082/test/transaction-commit"
run_test "microservice-artemis / transaction-rollback" "http://localhost:8082/test/transaction-rollback"
run_test "microservice-artemis / request-reply"        "http://localhost:8082/test/request-reply"
run_test "microservice-artemis / prefetch"             "http://localhost:8082/test/prefetch?count=50&sizeKb=10"

if [ "$QUICK_MODE" = false ]; then
  run_test "microservice-artemis / large-message"      "http://localhost:8082/test/large-message"
fi

# ----------------------------------------------------------
# k6 load tests (optional)
# ----------------------------------------------------------
if [ "$RUN_K6" = true ]; then
  echo ""
  echo "=============================================="
  echo "  k6 Load Tests"
  echo "=============================================="
  echo ""

  if [ -d "k6" ] && ls k6/*.js 1>/dev/null 2>&1; then
    for script in k6/*.js; do
      scriptname=$(basename "$script")
      log "Running k6: $scriptname"
      docker compose --profile k6 run --rm k6 run "/scripts/$scriptname" || {
        fail "k6 / $scriptname"
      }
    done
  else
    warn "No k6 scripts found in test/k6/. Skipping."
  fi
fi

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
echo ""
echo "=============================================="
echo "  Results"
echo "=============================================="
echo ""
echo -e "  ${GREEN}Passed: $PASSED${NC}"
echo -e "  ${RED}Failed: $FAILED${NC}"
echo ""

{
  echo ""
  echo "=========================================="
  echo "  Results: Passed=$PASSED  Failed=$FAILED"
  echo "=========================================="
} >> "$RESULTS_FILE"

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "  Failures:"
  echo "  Failures:" >> "$RESULTS_FILE"
  for err in "${ERRORS[@]}"; do
    echo -e "    ${RED}- $err${NC}"
    echo "    - $err" >> "$RESULTS_FILE"
  done
  echo ""
fi

echo "  Results saved to: $RESULTS_FILE"
echo ""
echo "  Broker consoles:"
echo "    Classic KahaDB: http://localhost:8161/admin  (admin/admin)"
echo "    Classic JDBC:   http://localhost:8163/admin  (admin/admin)"
echo "    Artemis:        http://localhost:8162/console (admin/admin)"
echo "    PostgreSQL:     localhost:5432 (activemq/activemq)"
echo ""
echo "  To stop:  docker compose down"
echo "  To clean: docker compose down -v --rmi local"
echo ""

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
