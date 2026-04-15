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
    -i, --interval SECONDS   Sampling interval for throughput (default: \$AMQ_SAMPLE_INTERVAL or 60)
    --help                   Show this help

Environment variables:
    AMQ_DB_HOST, AMQ_DB_PORT, AMQ_DB_NAME, AMQ_DB_USER, AMQ_DB_TABLE, AMQ_SAMPLE_INTERVAL
    PGPASSWORD               PostgreSQL password (or use .pgpass)

Examples:
    $(basename "$0") -h rds-endpoint.us-east-2.rds.amazonaws.com -d activemq -U admin
    $(basename "$0") -s                     # sizes only
    $(basename "$0") -r -i 120              # throughput with 2 min sample
    PGPASSWORD=secret $(basename "$0") -h mydb.rds.amazonaws.com -d amqdb -U admin
EOF
    exit 0
}

RUN_SIZES=true
RUN_THROUGHPUT=true

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host) DB_HOST="$2"; shift 2 ;;
        -p|--port) DB_PORT="$2"; shift 2 ;;
        -d|--database) DB_NAME="$2"; shift 2 ;;
        -U|--user) DB_USER="$2"; shift 2 ;;
        -t|--table) DB_TABLE="$2"; shift 2 ;;
        -s|--sizes-only) RUN_THROUGHPUT=false; shift ;;
        -r|--throughput-only) RUN_SIZES=false; shift ;;
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

echo ""
echo -e "${BOLD}${GREEN}=== Done ===${RESET}"
