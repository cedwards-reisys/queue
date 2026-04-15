# ActiveMQ Analysis Guide

Gather message size distribution and consumer processing metrics to inform the Artemis migration sizing. Two data sources: PostgreSQL JDBC store (message sizes) and New Relic (consumer performance).

---

## 1. Message Size Analysis (PostgreSQL)

The `scripts/amq-analyze.sh` script queries the ActiveMQ JDBC persistence store directly.

### Prerequisites

- `psql` client installed
- Network access to the RDS instance
- Read-only credentials for the ActiveMQ database

### Running the Script

```bash
# Full analysis — sizes + throughput estimation (60s sample)
PGPASSWORD=secret ./scripts/amq-analyze.sh \
  -h your-rds-endpoint.us-east-2.rds.amazonaws.com \
  -d activemq \
  -U admin

# Message sizes only (instant, no waiting)
PGPASSWORD=secret ./scripts/amq-analyze.sh -s \
  -h your-rds-endpoint.us-east-2.rds.amazonaws.com \
  -d activemq \
  -U admin

# Throughput estimation only with 5-minute sample (more accurate)
PGPASSWORD=secret ./scripts/amq-analyze.sh -r -i 300 \
  -h your-rds-endpoint.us-east-2.rds.amazonaws.com \
  -d activemq \
  -U admin
```

### What the Script Reports

| Report | What it tells us | Why it matters |
|---|---|---|
| Store Summary | Total messages, queue count, largest message | Overall scale of the system |
| Per-Queue Size Stats | min/avg/p95/max per queue | Identifies which queues carry large payloads |
| Size Distribution Buckets | Histogram of message sizes with visual bar chart | Shows the shape of the distribution |
| Large Message Threshold | Queues with messages >100KB | These will use Artemis large message streaming |
| Drain Rate Estimation | Net consumption rate per queue | Rough consumer throughput baseline |
| Processing Time Estimate | Estimated per-message time from drain rate | Informs HPA scaling thresholds |

### Script Options

| Flag | Default | Description |
|---|---|---|
| `-h, --host` | `$AMQ_DB_HOST` or `localhost` | RDS endpoint |
| `-p, --port` | `$AMQ_DB_PORT` or `5432` | Database port |
| `-d, --database` | `$AMQ_DB_NAME` or `activemq` | Database name |
| `-U, --user` | `$AMQ_DB_USER` or `activemq` | Database user |
| `-t, --table` | `$AMQ_DB_TABLE` or `ACTIVEMQ_MSGS` | Message table name |
| `-s, --sizes-only` | — | Skip throughput estimation |
| `-r, --throughput-only` | — | Skip size analysis |
| `-i, --interval` | `$AMQ_SAMPLE_INTERVAL` or `60` | Seconds between throughput snapshots |

### Important Notes

- The script queries **pending messages only** — already consumed messages are deleted from the JDBC store
- Run during **peak hours** for the most representative size distribution
- Run during **steady-state consumption** (not during a batch job) for accurate throughput estimates
- The drain rate estimate assumes net consumption; if producers are active, the rate reflects `consumed - produced`
- If the table name differs from `ACTIVEMQ_MSGS`, use `-t` to override

### Manual Queries (If Needed)

If you prefer to run queries directly or the table schema differs:

#### Current store snapshot

```sql
SELECT
    COUNT(*) AS total_messages,
    COUNT(DISTINCT container) AS queue_count,
    pg_size_pretty(SUM(LENGTH(msg))::bigint) AS total_store_size,
    pg_size_pretty(AVG(LENGTH(msg))::bigint) AS overall_avg_size,
    pg_size_pretty(MAX(LENGTH(msg))::bigint) AS largest_message
FROM ACTIVEMQ_MSGS;
```

#### Per-queue size stats

```sql
SELECT
    container AS queue_name,
    COUNT(*) AS msg_count,
    pg_size_pretty(MIN(LENGTH(msg))::bigint) AS min_size,
    pg_size_pretty(AVG(LENGTH(msg))::bigint) AS avg_size,
    pg_size_pretty(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY LENGTH(msg))::bigint) AS p95_size,
    pg_size_pretty(MAX(LENGTH(msg))::bigint) AS max_size,
    pg_size_pretty(SUM(LENGTH(msg))::bigint) AS total_size
FROM ACTIVEMQ_MSGS
GROUP BY container
ORDER BY AVG(LENGTH(msg)) DESC;
```

#### Size distribution buckets

```sql
SELECT
    CASE
        WHEN LENGTH(msg) < 1024 THEN '< 1 KB'
        WHEN LENGTH(msg) < 10240 THEN '1-10 KB'
        WHEN LENGTH(msg) < 102400 THEN '10-100 KB'
        WHEN LENGTH(msg) < 1048576 THEN '100 KB-1 MB'
        WHEN LENGTH(msg) < 10485760 THEN '1-10 MB'
        ELSE '> 10 MB'
    END AS size_bucket,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM ACTIVEMQ_MSGS
GROUP BY size_bucket
ORDER BY MIN(LENGTH(msg));
```

#### Queues with large messages (>100KB Artemis threshold)

```sql
SELECT
    container AS queue_name,
    COUNT(*) FILTER (WHERE LENGTH(msg) >= 102400) AS large_msg_count,
    COUNT(*) AS total_msg_count,
    ROUND(COUNT(*) FILTER (WHERE LENGTH(msg) >= 102400) * 100.0 / NULLIF(COUNT(*), 0), 1) AS large_pct,
    pg_size_pretty(AVG(LENGTH(msg)) FILTER (WHERE LENGTH(msg) >= 102400)::bigint) AS avg_large_size,
    pg_size_pretty(MAX(LENGTH(msg))::bigint) AS max_size
FROM ACTIVEMQ_MSGS
GROUP BY container
HAVING COUNT(*) FILTER (WHERE LENGTH(msg) >= 102400) > 0
ORDER BY COUNT(*) FILTER (WHERE LENGTH(msg) >= 102400) DESC;
```

---

## 2. Consumer Performance Analysis (New Relic)

New Relic's JVM agent auto-instruments `@JmsListener` methods in Spring Boot. No code changes needed.

### Where to Find JMS Metrics in the UI

1. **APM > Your Consumer App > Transactions**
   - Filter by `Other transactions` (JMS listeners are non-web transactions)
   - Look for `OtherTransaction/Message/JMS/Queue/{queueName}`
   - Each entry shows: response time, throughput, error rate

2. **APM > Your Consumer App > JMS** (if available)
   - Direct view of message throughput and processing time per queue

3. **APM > Your Consumer App > Distributed Tracing**
   - Traces that start with JMS consumption show full processing breakdown
   - Useful for identifying slow downstream calls (DB, HTTP, etc.)

### NRQL Queries

Run these in **New Relic > Query Your Data** or add to a dashboard.

#### Per-queue processing time (last 7 days)

```sql
SELECT
    average(duration) AS 'Avg (s)',
    percentile(duration, 50) AS 'p50 (s)',
    percentile(duration, 95) AS 'p95 (s)',
    percentile(duration, 99) AS 'p99 (s)',
    max(duration) AS 'Max (s)',
    count(*) AS 'Total Messages'
FROM Transaction
WHERE transactionType = 'Other'
AND name LIKE 'OtherTransaction/Message/JMS/Queue/%'
FACET name
SINCE 7 days ago
```

#### Message throughput per queue over time

```sql
SELECT rate(count(*), 1 minute) AS 'msgs/min'
FROM Transaction
WHERE transactionType = 'Other'
AND name LIKE 'OtherTransaction/Message/JMS/Queue/%'
FACET name
SINCE 7 days ago
TIMESERIES AUTO
```

#### Peak throughput per queue

```sql
SELECT max(msgs_per_min) AS 'Peak msgs/min'
FROM (
    SELECT rate(count(*), 1 minute) AS msgs_per_min
    FROM Transaction
    WHERE transactionType = 'Other'
    AND name LIKE 'OtherTransaction/Message/JMS/Queue/%'
    FACET name
    TIMESERIES 1 minute
    SINCE 7 days ago
)
FACET name
```

#### Error rate per queue

```sql
SELECT
    count(*) AS 'Total',
    filter(count(*), WHERE error IS true) AS 'Errors',
    percentage(count(*), WHERE error IS true) AS 'Error %'
FROM Transaction
WHERE transactionType = 'Other'
AND name LIKE 'OtherTransaction/Message/JMS/Queue/%'
FACET name
SINCE 7 days ago
```

#### Slow queues (p95 > 1 second)

```sql
SELECT
    percentile(duration, 95) AS 'p95 (s)',
    average(duration) AS 'Avg (s)',
    count(*) AS 'Volume'
FROM Transaction
WHERE transactionType = 'Other'
AND name LIKE 'OtherTransaction/Message/JMS/Queue/%'
FACET name
SINCE 7 days ago
HAVING percentile(duration, 95) > 1
```

#### Processing time by message size correlation

If you want to see whether larger messages take longer (run after you know which queues carry large messages from the Postgres analysis):

```sql
SELECT
    average(duration) AS 'Avg Processing (s)',
    percentile(duration, 95) AS 'p95 (s)',
    count(*) AS 'Volume'
FROM Transaction
WHERE transactionType = 'Other'
AND name LIKE 'OtherTransaction/Message/JMS/Queue/%'
FACET name
SINCE 7 days ago
TIMESERIES 1 hour
```

Compare the time-series patterns of queues identified as carrying large messages vs small-message queues.

### What to Look For

| Metric | What it tells us | Action |
|---|---|---|
| **p95 processing time** | Drives HPA scaling thresholds | >1s = needs more consumers or dedicated pool |
| **Peak throughput** | Burst capacity requirement | Size consumer HPA maxReplicas |
| **Error rate per queue** | Poison message frequency | Tune `max-delivery-attempts` per queue group |
| **Slow queues** | Candidates for separate consumer deployment | Isolate from fast queues to prevent starvation |
| **Throughput patterns** | When bursts happen | Inform pre-scaling or HPA responsiveness tuning |

---

## 3. What to Report Back

After running both analyses, the following data points feed directly into the Artemis migration design:

### From PostgreSQL Analysis

- [ ] Total queue count
- [ ] Per-queue average message size
- [ ] Per-queue max message size
- [ ] Number of queues with messages >100KB (Artemis large message threshold)
- [ ] Which specific queues carry PDFs / large payloads
- [ ] Total pending message volume (for EBS sizing)

### From New Relic Analysis

- [ ] Per-queue p50/p95/p99 processing time
- [ ] Per-queue throughput (msgs/min average and peak)
- [ ] Error rate per queue (DLQ frequency)
- [ ] Which queues are slow (p95 > 1s) — candidates for isolated consumer deployments
- [ ] Burst patterns — when do peaks happen, how long do they last

### How This Informs the Design

| Data point | Design decision |
|---|---|
| Message size distribution | Artemis `min-large-message-size` threshold, EBS volume sizing |
| Queues with large messages | Candidate queues for future S3 claim check iteration |
| Consumer processing time | HPA `queueDepthTarget` (target msgs per consumer pod) |
| Peak throughput | HPA `maxReplicas`, cluster group count |
| Slow queues (>1s p95) | Separate consumer Deployment + independent HPA |
| Error rates | Per-queue `max-delivery-attempts`, DLQ alerting thresholds |
| Burst patterns | HPA `scaleUp.stabilizationWindowSeconds` tuning |
