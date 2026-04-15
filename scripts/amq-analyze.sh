#!/usr/bin/env bash
set -euo pipefail

# ActiveMQ JDBC Store Analyzer
# Queries PostgreSQL persistence store for message size distribution
# and estimates consumer throughput (drain rate)

# --- Configuration ---
DB_HOST="${AMQ_DB_HOST:-localhost}"
DB_PORT="${AMQ_DB_PORT:-5432}"
DB_NAME="${AMQ_DB_NAME:-activemq}"
DB_USER="${AMQ_DB_USER:-activemq}"
DB_TABLE="${AMQ_DB_TABLE:-ACTIVEMQ_MSGS}"
SAMPLE_INTERVAL="${AMQ_SAMPLE_INTERVAL:-60}"

# --- Colors ---
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Analyze ActiveMQ JDBC persistence store in PostgreSQL.

Options:
    -h, --host HOST          Database host (default: \$AMQ_DB_HOST or localhost)
    -p, --port PORT          Database port (default: \$AMQ_DB_PORT or 5432)
    -d, --database NAME      Database name (default: \$AMQ_DB_NAME or activemq)
    -U, --user USER          Database user (default: \$AMQ_DB_USER or activemq)
    -t, --table TABLE        Message table name (default: \$AMQ_DB_TABLE or ACTIVEMQ_MSGS)
    -s, --sizes-only         Run size analysis only (skip throughput estimation)
    -r, --throughput-only    Run throughput estimation only (skip size analysis)
    -c, --connections        Show connection distribution by client IP (requires JMX HTTP or broker host)
    -b, --broker-url URL     Broker admin URL for connection analysis (default: \$AMQ_BROKER_URL or http://localhost:8161)
    -i, --interval SECONDS   Sampling interval for throughput (default: \$AMQ_SAMPLE_INTERVAL or 60)
    --help                   Show this help

Environment variables:
    AMQ_DB_HOST, AMQ_DB_PORT, AMQ_DB_NAME, AMQ_DB_USER, AMQ_DB_TABLE, AMQ_SAMPLE_INTERVAL
    AMQ_BROKER_URL           Broker admin URL (default: http://localhost:8161)
    AMQ_BROKER_USER          Broker admin user (default: admin)
    AMQ_BROKER_PASS          Broker admin password (default: admin)
    PGPASSWORD               PostgreSQL password (or use .pgpass)

Examples:
    $(basename "$0") -h rds-endpoint.us-east-2.rds.amazonaws.com -d activemq -U admin
    $(basename "$0") -s                     # sizes only
    $(basename "$0") -r -i 120              # throughput with 2 min sample
    PGPASSWORD=secret $(basename "$0") -h mydb.rds.amazonaws.com -d amqdb -U admin
    $(basename "$0") -c                        # connection analysis only
    $(basename "$0") -c -b http://broker:8161  # connections against specific broker
EOF
    exit 0
}

BROKER_URL="${AMQ_BROKER_URL:-http://localhost:8161}"
BROKER_USER="${AMQ_BROKER_USER:-admin}"
BROKER_PASS="${AMQ_BROKER_PASS:-admin}"

RUN_SIZES=true
RUN_THROUGHPUT=true
RUN_CONNECTIONS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host) DB_HOST="$2"; shift 2 ;;
        -p|--port) DB_PORT="$2"; shift 2 ;;
        -d|--database) DB_NAME="$2"; shift 2 ;;
        -U|--user) DB_USER="$2"; shift 2 ;;
        -t|--table) DB_TABLE="$2"; shift 2 ;;
        -s|--sizes-only) RUN_THROUGHPUT=false; RUN_CONNECTIONS=false; shift ;;
        -r|--throughput-only) RUN_SIZES=false; RUN_CONNECTIONS=false; shift ;;
        -c|--connections) RUN_CONNECTIONS=true; RUN_SIZES=false; RUN_THROUGHPUT=false; shift ;;
        -b|--broker-url) BROKER_URL="$2"; shift 2 ;;
        -i|--interval) SAMPLE_INTERVAL="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# --- Preflight ---
if ! command -v psql &>/dev/null; then
    echo "Error: psql not found. Install postgresql-client."
    exit 1
fi

PSQL="psql -h ${DB_HOST} -p ${DB_PORT} -d ${DB_NAME} -U ${DB_USER} -X --no-align"
PSQL_PRETTY="psql -h ${DB_HOST} -p ${DB_PORT} -d ${DB_NAME} -U ${DB_USER} -X"

echo -e "${BOLD}ActiveMQ JDBC Store Analyzer${RESET}"
echo -e "Host: ${CYAN}${DB_HOST}:${DB_PORT}/${DB_NAME}${RESET}  Table: ${CYAN}${DB_TABLE}${RESET}"
echo ""

# Test connection
if ! ${PSQL} -c "SELECT 1" &>/dev/null; then
    echo "Error: Cannot connect to PostgreSQL at ${DB_HOST}:${DB_PORT}/${DB_NAME}"
    echo "Set PGPASSWORD or configure .pgpass"
    exit 1
fi

# --- 1. Total message count ---
echo -e "${BOLD}${GREEN}=== Current Store Summary ===${RESET}"
${PSQL_PRETTY} -c "
SELECT
    COUNT(*) AS total_messages,
    COUNT(DISTINCT container) AS queue_count,
    pg_size_pretty(SUM(LENGTH(msg))::bigint) AS total_store_size,
    pg_size_pretty(AVG(LENGTH(msg))::bigint) AS overall_avg_size,
    pg_size_pretty(MAX(LENGTH(msg))::bigint) AS largest_message
FROM ${DB_TABLE};
"

if [[ "${RUN_SIZES}" == "true" ]]; then
    # --- 2. Per-queue size stats ---
    echo ""
    echo -e "${BOLD}${GREEN}=== Per-Queue Size Statistics ===${RESET}"
    ${PSQL_PRETTY} -c "
    SELECT
        container AS queue_name,
        COUNT(*) AS msg_count,
        pg_size_pretty(MIN(LENGTH(msg))::bigint) AS min_size,
        pg_size_pretty(AVG(LENGTH(msg))::bigint) AS avg_size,
        pg_size_pretty((PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY LENGTH(msg)))::bigint) AS p95_size,
        pg_size_pretty(MAX(LENGTH(msg))::bigint) AS max_size,
        pg_size_pretty(SUM(LENGTH(msg))::bigint) AS total_size
    FROM ${DB_TABLE}
    GROUP BY container
    ORDER BY AVG(LENGTH(msg)) DESC;
    "

    # --- 3. Size distribution buckets (all queues) ---
    echo ""
    echo -e "${BOLD}${GREEN}=== Overall Size Distribution ===${RESET}"
    ${PSQL_PRETTY} -c "
    SELECT
        bucket AS size_bucket,
        count,
        ROUND(count * 100.0 / NULLIF(SUM(count) OVER (), 0), 1) AS pct,
        REPEAT('█', LEAST((count * 50 / NULLIF(MAX(count) OVER (), 0))::int, 50)) AS bar
    FROM (
        SELECT
            CASE
                WHEN LENGTH(msg) < 1024 THEN '1. < 1 KB'
                WHEN LENGTH(msg) < 10240 THEN '2. 1-10 KB'
                WHEN LENGTH(msg) < 102400 THEN '3. 10-100 KB'
                WHEN LENGTH(msg) < 1048576 THEN '4. 100 KB-1 MB'
                WHEN LENGTH(msg) < 10485760 THEN '5. 1-10 MB'
                ELSE '6. > 10 MB'
            END AS bucket,
            COUNT(*) AS count
        FROM ${DB_TABLE}
        GROUP BY bucket
    ) sub
    ORDER BY bucket;
    "

    # --- 4. Size distribution per queue ---
    echo ""
    echo -e "${BOLD}${GREEN}=== Per-Queue Size Distribution ===${RESET}"
    ${PSQL_PRETTY} -c "
    SELECT
        container AS queue_name,
        CASE
            WHEN LENGTH(msg) < 1024 THEN '< 1 KB'
            WHEN LENGTH(msg) < 10240 THEN '1-10 KB'
            WHEN LENGTH(msg) < 102400 THEN '10-100 KB'
            WHEN LENGTH(msg) < 1048576 THEN '100 KB-1 MB'
            WHEN LENGTH(msg) < 10485760 THEN '1-10 MB'
            ELSE '> 10 MB'
        END AS size_bucket,
        COUNT(*) AS count,
        ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY container), 0), 1) AS pct
    FROM ${DB_TABLE}
    GROUP BY container, size_bucket
    ORDER BY container, MIN(LENGTH(msg));
    "

    # --- 5. Queues carrying large messages (>100KB = Artemis large message threshold) ---
    echo ""
    echo -e "${BOLD}${YELLOW}=== Queues Exceeding Artemis Large Message Threshold (>100 KB) ===${RESET}"
    ${PSQL_PRETTY} -c "
    SELECT
        container AS queue_name,
        COUNT(*) FILTER (WHERE LENGTH(msg) >= 102400) AS large_msg_count,
        COUNT(*) AS total_msg_count,
        ROUND(COUNT(*) FILTER (WHERE LENGTH(msg) >= 102400) * 100.0 / NULLIF(COUNT(*), 0), 1) AS large_pct,
        pg_size_pretty(AVG(LENGTH(msg)) FILTER (WHERE LENGTH(msg) >= 102400)::bigint) AS avg_large_size,
        pg_size_pretty(MAX(LENGTH(msg))::bigint) AS max_size
    FROM ${DB_TABLE}
    GROUP BY container
    HAVING COUNT(*) FILTER (WHERE LENGTH(msg) >= 102400) > 0
    ORDER BY COUNT(*) FILTER (WHERE LENGTH(msg) >= 102400) DESC;
    "
fi

if [[ "${RUN_THROUGHPUT}" == "true" ]]; then
    # --- 6. Consumer throughput estimation ---
    echo ""
    echo -e "${BOLD}${GREEN}=== Consumer Throughput Estimation ===${RESET}"
    echo -e "Sampling queue depths over ${CYAN}${SAMPLE_INTERVAL}s${RESET} interval..."
    echo -e "This estimates drain rate (messages consumed per second per queue)."
    echo ""

    SNAP1=$(mktemp)
    SNAP2=$(mktemp)
    trap "rm -f ${SNAP1} ${SNAP2}" EXIT

    # Snapshot 1: queue name, pending count, timestamp
    ${PSQL} --tuples-only -c "
    SELECT
        container,
        COUNT(*),
        EXTRACT(EPOCH FROM NOW())::bigint
    FROM ${DB_TABLE}
    GROUP BY container
    ORDER BY container;
    " > "${SNAP1}"

    echo -e "  Snapshot 1 captured. Waiting ${SAMPLE_INTERVAL}s..."

    sleep "${SAMPLE_INTERVAL}"

    # Snapshot 2
    ${PSQL} --tuples-only -c "
    SELECT
        container,
        COUNT(*),
        EXTRACT(EPOCH FROM NOW())::bigint
    FROM ${DB_TABLE}
    GROUP BY container
    ORDER BY container;
    " > "${SNAP2}"

    echo -e "  Snapshot 2 captured."
    echo ""

    # Join and calculate delta
    echo -e "${BOLD}Queue Throughput (${SAMPLE_INTERVAL}s sample)${RESET}"
    echo ""
    printf "%-50s %10s %10s %10s %12s\n" "QUEUE" "SNAP1" "SNAP2" "DELTA" "MSGS/SEC"
    printf "%-50s %10s %10s %10s %12s\n" "-----" "-----" "-----" "-----" "--------"

    while IFS='|' read -r queue1 count1 ts1; do
        queue1=$(echo "${queue1}" | xargs)
        count1=$(echo "${count1}" | xargs)
        ts1=$(echo "${ts1}" | xargs)

        # Find matching queue in snap2
        match=$(awk -F'|' -v q="${queue1}" '{gsub(/^[ \t]+|[ \t]+$/, "", $1)} $1 == q' "${SNAP2}" 2>/dev/null || true)
        if [[ -n "${match}" ]]; then
            count2=$(echo "${match}" | cut -d'|' -f2 | xargs)
            ts2=$(echo "${match}" | cut -d'|' -f3 | xargs)
            delta=$((count1 - count2))
            elapsed=$((ts2 - ts1))
            if [[ ${elapsed} -gt 0 && ${delta} -gt 0 ]]; then
                rate=$(echo "scale=2; ${delta} / ${elapsed}" | bc)
                printf "%-50s %10d %10d %10d %10s/s\n" "${queue1}" "${count1}" "${count2}" "${delta}" "${rate}"
            elif [[ ${delta} -eq 0 ]]; then
                printf "%-50s %10d %10d %10s %12s\n" "${queue1}" "${count1}" "${count2}" "0" "idle"
            else
                # Negative delta = messages added faster than consumed
                gained=$(( delta * -1 ))
                printf "%-50s %10d %10d %10s %12s\n" "${queue1}" "${count1}" "${count2}" "+${gained}" "growing"
            fi
        fi
    done < "${SNAP1}"

    echo ""
    echo -e "${YELLOW}Notes:${RESET}"
    echo "  - 'idle'    = queue depth unchanged (consumers keeping up or no activity)"
    echo "  - 'growing' = producers outpacing consumers (depth increased)"
    echo "  - msgs/sec  = net drain rate (consumed - produced during sample)"
    echo "  - For accurate processing time, sample during steady-state consumption"
    echo "  - Run with -i 300 for a longer 5-minute sample for more accuracy"

    # Processing time estimate
    echo ""
    echo -e "${BOLD}${GREEN}=== Estimated Per-Message Processing Time ===${RESET}"
    echo -e "(Based on drain rate — assumes 1 consumer thread per queue)"
    echo ""
    printf "%-50s %12s %15s\n" "QUEUE" "DRAIN RATE" "EST. PROC TIME"
    printf "%-50s %12s %15s\n" "-----" "----------" "--------------"

    while IFS='|' read -r queue1 count1 ts1; do
        queue1=$(echo "${queue1}" | xargs)
        count1=$(echo "${count1}" | xargs)
        ts1=$(echo "${ts1}" | xargs)

        match=$(awk -F'|' -v q="${queue1}" '{gsub(/^[ \t]+|[ \t]+$/, "", $1)} $1 == q' "${SNAP2}" 2>/dev/null || true)
        if [[ -n "${match}" ]]; then
            count2=$(echo "${match}" | cut -d'|' -f2 | xargs)
            ts2=$(echo "${match}" | cut -d'|' -f3 | xargs)
            delta=$((count1 - count2))
            elapsed=$((ts2 - ts1))
            if [[ ${elapsed} -gt 0 && ${delta} -gt 0 ]]; then
                rate=$(echo "scale=2; ${delta} / ${elapsed}" | bc)
                est_ms=$(echo "scale=0; 1000 / ${rate}" | bc 2>/dev/null || echo "N/A")
                printf "%-50s %10s/s %13s ms\n" "${queue1}" "${rate}" "${est_ms}"
            fi
        fi
    done < "${SNAP1}"

    echo ""
    echo -e "${YELLOW}Caveat:${RESET} This is drain rate / consumer count. If a queue has N concurrent"
    echo "consumers, actual per-message time = estimate * N. Check your Spring Boot"
    echo "concurrency settings (spring.jms.listener.concurrency) per queue."
fi

if [[ "${RUN_CONNECTIONS}" == "true" ]]; then
    # --- Connection Distribution by Client IP ---
    # Uses Classic's Jolokia REST API (JMX over HTTP) to query broker connections.
    # Helps identify: connection leaks, missing pooling, noisy clients.
    echo ""
    echo -e "${BOLD}${GREEN}=== Connection Distribution by Client IP ===${RESET}"
    echo -e "Broker: ${CYAN}${BROKER_URL}${RESET}"
    echo ""

    # Check connectivity to broker admin
    JOLOKIA_URL="${BROKER_URL}/api/jolokia"
    if ! curl -sf -u "${BROKER_USER}:${BROKER_PASS}" "${JOLOKIA_URL}/version" &>/dev/null; then
        echo -e "${YELLOW}Warning: Cannot reach Jolokia at ${JOLOKIA_URL}${RESET}"
        echo "Ensure the broker admin console is accessible and credentials are correct."
        echo "Set AMQ_BROKER_URL, AMQ_BROKER_USER, AMQ_BROKER_PASS as needed."
    else
        # Query total connection count
        CONN_COUNT=$(curl -sf -u "${BROKER_USER}:${BROKER_PASS}" \
            "${JOLOKIA_URL}/read/org.apache.activemq:type=Broker,brokerName=localhost/CurrentConnectionsCount" \
            2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('value','N/A'))" 2>/dev/null || echo "N/A")
        echo -e "Total broker connections: ${BOLD}${CONN_COUNT}${RESET}"
        echo ""

        # Query all connections — Classic exposes each as a JMX Connection MBean
        # MBean pattern: org.apache.activemq:type=Broker,brokerName=*,connectorName=*,connectionViewType=clientId,connectionName=*
        CONN_JSON=$(curl -sf -u "${BROKER_USER}:${BROKER_PASS}" \
            "${JOLOKIA_URL}/search/org.apache.activemq:type=Broker,brokerName=*,connectorName=*,connectionViewType=clientId,connectionName=*" \
            2>/dev/null || echo '{"value":[]}')

        # Extract RemoteAddress from each connection MBean and aggregate by IP
        echo -e "${BOLD}Connections per Client IP:${RESET}"
        echo ""
        printf "%-40s %10s %8s  %s\n" "CLIENT IP" "CONNS" "PCT" "BAR"
        printf "%-40s %10s %8s  %s\n" "---------" "-----" "---" "---"

        echo "${CONN_JSON}" | python3 -c "
import sys, json, urllib.request, base64

data = json.load(sys.stdin)
mbeans = data.get('value', [])

if not mbeans:
    print('  No connection MBeans found.')
    sys.exit(0)

broker_url = '${JOLOKIA_URL}'
auth = base64.b64encode('${BROKER_USER}:${BROKER_PASS}'.encode()).decode()

# Batch read RemoteAddress from each connection MBean
ips = {}
for mbean in mbeans:
    try:
        url = f\"{broker_url}/read/{urllib.parse.quote(mbean, safe='')}/RemoteAddress\"
        req = urllib.request.Request(url, headers={'Authorization': f'Basic {auth}'})
        resp = urllib.request.urlopen(req, timeout=5)
        result = json.loads(resp.read())
        addr = result.get('value', 'unknown')
        # RemoteAddress is typically 'tcp://IP:port' — extract just the IP
        ip = addr.replace('tcp://', '').rsplit(':', 1)[0] if '://' in addr else addr.rsplit(':', 1)[0]
        ips[ip] = ips.get(ip, 0) + 1
    except Exception:
        ips['(error)'] = ips.get('(error)', 0) + 1

total = sum(ips.values())
max_count = max(ips.values()) if ips else 1

for ip, count in sorted(ips.items(), key=lambda x: -x[1]):
    pct = count * 100.0 / total if total > 0 else 0
    bar_len = int(count * 40 / max_count) if max_count > 0 else 0
    bar = '█' * bar_len
    print(f'{ip:<40s} {count:>10d} {pct:>7.1f}%  {bar}')

print()
print(f'Total unique client IPs: {len(ips)}')
print(f'Average connections per IP: {total / len(ips):.1f}' if ips else '')
" 2>/dev/null

        # Idle vs active breakdown
        echo ""
        echo -e "${BOLD}Connection Idle Analysis:${RESET}"
        echo ""
        echo "${CONN_JSON}" | python3 -c "
import sys, json, urllib.request, base64, time

data = json.load(sys.stdin)
mbeans = data.get('value', [])

if not mbeans:
    sys.exit(0)

broker_url = '${JOLOKIA_URL}'
auth = base64.b64encode('${BROKER_USER}:${BROKER_PASS}'.encode()).decode()

active = 0
idle = 0
idle_threshold = 300  # 5 min — connections with no dispatch in this window are 'idle'

for mbean in mbeans:
    try:
        url = f\"{broker_url}/read/{urllib.parse.quote(mbean, safe='')}/DispatchQueueSize\"
        req = urllib.request.Request(url, headers={'Authorization': f'Basic {auth}'})
        resp = urllib.request.urlopen(req, timeout=5)
        result = json.loads(resp.read())
        dispatch_size = int(result.get('value', 0))
        if dispatch_size > 0:
            active += 1
        else:
            idle += 1
    except Exception:
        pass

total = active + idle
print(f'  Active (dispatching):  {active:>6d}  ({active*100/total:.1f}%)' if total else '')
print(f'  Idle (no dispatch):    {idle:>6d}  ({idle*100/total:.1f}%)' if total else '')
print(f'  Total:                 {total:>6d}')
print()
if idle > total * 0.5:
    print('  ⚠ Over 50% idle connections — likely missing connection pooling or leaked connections.')
    print('  Check client-side CachingConnectionFactory / pooled-jms configuration.')
elif idle > total * 0.3:
    print('  Note: 30-50% idle — may be normal for bursty workloads, but worth investigating.')
else:
    print('  Connection utilization looks healthy.')
" 2>/dev/null

        echo ""
        echo -e "${YELLOW}Notes:${RESET}"
        echo "  - High connection count from a single IP = likely missing connection pooling"
        echo "  - Many IPs with 1-2 connections each = healthy, well-pooled clients"
        echo "  - Connections per IP ≈ ASG instance count × pool size per instance"
        echo "  - If total connections >> (instance count × expected pool size), investigate leaks"
        echo "  - Compare with NR data to cross-validate: connections here should match NR APM connection metrics"
    fi
fi

echo ""
echo -e "${BOLD}${GREEN}=== Done ===${RESET}"
