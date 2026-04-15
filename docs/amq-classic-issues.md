# ActiveMQ Classic — Known Issues and Why Artemis Fixes Them

## The Problem

ActiveMQ Classic with JDBC persistence (PostgreSQL) exhibits a pattern where the broker "stops working" — no failover, no error logs, no resource spikes. Increasing instance size does not improve performance.

## Why Bigger Instances Don't Help

The bottleneck is PostgreSQL, not the broker.

```
Producer → ActiveMQ Classic → INSERT into msgs table → PostgreSQL RDS
Consumer → ActiveMQ Classic → SELECT + DELETE from msgs table → PostgreSQL RDS
```

Every message is a database round-trip. Bigger broker CPU/RAM doesn't matter when the broker is waiting on PostgreSQL to commit. The broker spends most of its time idle, waiting on network I/O to the database.

## Why It "Stops Working" with No Errors

The JDBC store lock mechanism is the root cause. Classic uses a row in a database lock table to coordinate master/slave. Here's the likely failure sequence:

```
1. Master holds store lock (row in lock table)
2. Lock keepalive fails silently (GC pause, network blip, PG connection timeout)
3. Master THINKS it's still master — keeps accepting connections
4. But it can't write to the store — messages accepted, never persisted
5. Slave sees expired lock but CAN'T acquire it (race condition / stale connection)
6. Result: zombie master + stuck slave = cluster looks alive, processes nothing
```

No errors because Classic doesn't detect this state. No resource spikes because the broker isn't doing work — it's stuck waiting on a database lock that's in limbo.

## Other Common Silent Failures with Classic + JDBC

| Symptom | Likely Cause |
|---|---|
| Broker "freezes" periodically | PostgreSQL `VACUUM` on the messages table |
| Slow drain, messages pile up | Messages table >1M rows, full table scans on dequeue |
| Failover takes 30+ seconds or never happens | `lockKeepAlivePeriod` too aggressive, JDBC connection pool exhaustion |
| Slave never promotes | Stale lock row, slave can't acquire |
| Memory climbs despite low queue depth | Classic pre-fetches messages into heap, JDBC adapter doesn't page efficiently |
| Performance degrades over time | Messages table bloat — PostgreSQL doesn't reclaim space from DELETEs without VACUUM |

## How Artemis Fixes Each Issue

| Classic + JDBC | Artemis + Journal | Why It's Better |
|---|---|---|
| Every msg = DB round-trip | Every msg = local disk append | No network hop. ASYNCIO (libaio) does direct I/O to EBS. Throughput is local disk speed, not database latency. |
| Lock table for HA | Replication protocol for HA | Live replicates journal to backup over a dedicated TCP connection. No shared database, no lock table, no stale rows. |
| Failover depends on DB lock release | Failover is broker-to-broker, quorum-based | Backup detects live failure via replication heartbeat. Quorum vote confirms. No database involved in failover decision. |
| "Zombie master" is a known failure mode | Quorum vote — broker knows if it's live or not | If live broker loses quorum, it shuts itself down. No zombie state possible. |
| Bigger instance doesn't help (DB bound) | Bigger instance directly helps (local I/O bound) | CPU, memory, and disk IOPS all directly improve Artemis throughput. No external bottleneck. |
| No good built-in metrics | JMX exporter → Prometheus | Full observability: queue depth, message rates, consumer counts, disk usage, replication sync status, connection counts. |
| Messages table bloat over time | Journal compaction is automatic | Artemis reclaims journal space as messages are consumed. No equivalent of PostgreSQL table bloat. |
| Connection pool exhaustion to DB | No database connections | Eliminates an entire failure domain. |

## JDBC Store Lock — Deeper Explanation

Classic's master/slave HA relies on an exclusive row lock in the database:

```sql
-- Classic creates this table
CREATE TABLE ACTIVEMQ_LOCK (
    ID          BIGINT NOT NULL,
    TIME        BIGINT,
    BROKER_NAME VARCHAR(250),
    PRIMARY KEY (ID)
);

-- Master holds lock by periodically updating TIME
UPDATE ACTIVEMQ_LOCK SET TIME=?, BROKER_NAME=? WHERE ID=1
```

The failure modes:

1. **GC pause**: Master's JVM pauses for garbage collection. Lock keepalive misses. PostgreSQL connection may timeout. When GC ends, master resumes thinking it has the lock, but the row may be stale.

2. **Network partition**: Master loses connectivity to PostgreSQL but not to clients. Accepts messages it can't persist. Slave can't see the master is unhealthy because it's also checking via the same database.

3. **Connection pool exhaustion**: Under load, the broker's connection pool to PostgreSQL fills up. Lock keepalive competes with message persistence for pool slots. Keepalive fails, lock expires, but no connections available for slave to acquire it either.

4. **PostgreSQL maintenance**: `VACUUM` or `ANALYZE` on the messages table blocks the lock update. Long-running maintenance = missed keepalive = potential false failover or zombie master.

Artemis eliminates all of these by removing the database from the HA decision path entirely.

## Artemis Replication HA — How It Works Instead

```
┌─────────────┐     replication channel     ┌──────────────┐
│  Live Broker│ ──────────────────────────► │ Backup Broker│
│  (active)   │   journal data + state      │  (standby)   │
└─────────────┘                             └──────────────┘
       │                                            │
       │ heartbeat (TCP)                            │ monitors heartbeat
       │────────────────────────────────────────────│
```

1. Live broker replicates every journal write to backup over a dedicated TCP connection
2. Backup confirms receipt — live only acknowledges to producer after backup confirms (synchronous replication)
3. Backup monitors heartbeat from live
4. If heartbeat stops, backup initiates quorum vote
5. With `quorum-size: 1` (2-AZ deployment), backup self-promotes immediately
6. Clients reconnect via K8s Service (ClusterIP routes to new live)
7. No database involved at any step

## What to Investigate on Current Classic Setup

Before migrating, capture these data points to confirm the diagnosis:

```bash
# Check for zombie master symptoms
# Look for gaps in the lock table updates
psql -h $RDS_HOST -U $DB_USER -d $DB_NAME -c \
  "SELECT * FROM ACTIVEMQ_LOCK ORDER BY ID;"

# Check messages table size (bloat indicator)
psql -h $RDS_HOST -U $DB_USER -d $DB_NAME -c \
  "SELECT pg_size_pretty(pg_total_relation_size('ACTIVEMQ_MSGS'));"

# Check for long-running VACUUM or queries
psql -h $RDS_HOST -U $DB_USER -d $DB_NAME -c \
  "SELECT pid, state, query_start, query FROM pg_stat_activity
   WHERE datname = '$DB_NAME' AND state != 'idle'
   ORDER BY query_start;"

# Check Classic broker logs for lock-related warnings
grep -i "lock\|failover\|slave\|master" /var/log/activemq/activemq.log

# Check JDBC connection pool health
grep -i "pool\|connection\|timeout\|exhausted" /var/log/activemq/activemq.log
```

These queries may reveal the smoking gun — a bloated messages table, stale lock rows, or connection pool exhaustion that explains the silent failures.
