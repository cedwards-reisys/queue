# JMS Performance Tuning Guide

Reference for tuning ActiveMQ Classic and Artemis in the monolith-to-microservice migration.

## Test Results Summary

### Direct Broker Benchmark (no Spring, no HTTP)

Artemis `perf client` running inside the container — pure JMS throughput:

| Metric | Artemis CORE |
|---|---|
| Sustained throughput | **77,000 msg/sec** |
| Peak (1s burst) | **92,146 msg/sec** |
| Total in 30s | **2,315,678 messages** |
| Send ack p50 | 40 microseconds |
| Send ack p99 | 345 microseconds |
| Transfer p50 | 423 microseconds |

The broker is not the bottleneck. These numbers prove Artemis can handle enterprise workloads with room to spare.

### Application-Level Throughput (HTTP → Spring → JMS → Broker)

#### Moderate Load (4 paths parallel, 10→50 msg/sec each)

| Path | avg | med | p95 | max | Failures |
|---|---|---|---|---|---|
| Classic KahaDB | 1.7ms | 1ms | 3ms | 272ms | 0% |
| Classic JDBC | 2.2ms | 2ms | 4ms | 266ms | 0% |
| Artemis (OpenWire) | 2.6ms | 2ms | 6ms | 296ms | 0% |
| Artemis (native) | 5.7ms | 5ms | 7ms | 196ms | 0% |

9,600 total iterations, 137 req/sec aggregate, 0% failure rate.

#### Max Throughput (produce-only, 100→2000 msg/sec ramp)

| Path | Effective Rate | p95 | Dropped | VUs Used | Failures |
|---|---|---|---|---|---|
| Classic KahaDB | **842 req/s** | 0.89ms | 0 | 1 | 0% |
| Classic JDBC | **842 req/s** | 1.27ms | 0 | 4 | 0% |
| Artemis (OpenWire) | **184 req/s** | 4.77ms | 33,399 | 500 | 0% |
| Artemis (native) | **183 req/s** | 5.23ms | 33,539 | 500 | 0% |

Classic paths appear faster because the monolith-sim (Java 8, Spring Boot 2.7, activemq-pool) has lower overhead than the microservice-sim (Java 21, Spring Boot 3.4, pooled-jms). This is an app-stack difference, not a broker difference.

### Before vs After Tuning (native client)

| Metric | Before (no pool) | After (pooled-jms) | Improvement |
|---|---|---|---|
| avg | 11.9ms | 10.4ms | 13% |
| p95 | 33ms | 24ms | 27% |
| max | 178ms | 131ms | 26% |

---

## Client-Side Tuning

### Connection Pooling

The single most impactful client-side optimization. Without pooling, every JMS operation creates a new TCP connection, performs AMQP/OpenWire handshake, authenticates, and tears down — adding 5-30ms per request.

#### Classic (activemq-pool)

```java
PooledConnectionFactory pooled = new PooledConnectionFactory();
pooled.setConnectionFactory(activeMQConnectionFactory);
pooled.setMaxConnections(20);
pooled.setMaximumActiveSessionPerConnection(500);
pooled.setIdleTimeout(30000);
```

#### Artemis native (pooled-jms)

```java
// org.messaginghub:pooled-jms:3.1.7
JmsPoolConnectionFactory pool = new JmsPoolConnectionFactory();
pool.setConnectionFactory(artemisConnectionFactory);
pool.setMaxConnections(20);
pool.setMaxSessionsPerConnection(500);
pool.setConnectionIdleTimeout(30000);
```

| Parameter | Default | Tuned | Effect |
|---|---|---|---|
| maxConnections | 1 | 20 | Max TCP connections in pool. Too low = contention under load. Too high = broker socket exhaustion |
| maxSessions | 500 | 500 | Sessions per connection. JMS sessions are lightweight but consume broker memory |
| idleTimeout | 30s | 30s | Close idle connections. Set lower in serverless, higher in steady-state |

**When NOT to use pooling:**
- Tests that need precise session lifecycle control (transaction tests, temp queue tests)
- Keep a `rawConnectionFactory` bean for these cases

**Sizing guidance:**
- `maxConnections` = expected concurrent threads / 5 (sessions multiplex over connections)
- Monitor `pool.getNumActive()` in production — if consistently at max, increase

### Prefetch Size

Controls how many messages the broker pushes to the consumer before acknowledgement.

| Setting | Throughput | Fairness | Heap Impact |
|---|---|---|---|
| High (1000, default) | Best — broker pushes bulk | Poor — one consumer hogs messages | High — all prefetched messages in memory |
| Medium (50-100) | Good | Good | Moderate |
| Low (1-10) | Poor — round-trip per message | Best — even distribution | Minimal |

**Classic (OpenWire):**
```
brokerUrl + "?jms.prefetchPolicy.all=100"
```

**Artemis (native) — consumer window size:**
```java
factory.setConsumerWindowSize(1048576); // 1MB window = ~100 x 10KB messages
factory.setConsumerWindowSize(0);       // disable prefetch = pull mode
```

**When to lower prefetch:**
- Large messages (PDFs, images) — high prefetch + 1MB messages = OOM
- Multiple consumers on same queue needing fair dispatch
- Our test showed OpenWire on Artemis uses **480KB per message** vs **247KB on Classic** — halve prefetch when migrating

**When to keep high:**
- Small messages, single consumer, throughput is priority
- Batch processing workloads

### Acknowledge Modes

| Mode | Throughput | Reliability | Use Case |
|---|---|---|---|
| AUTO_ACKNOWLEDGE | Highest | At-most-once (message lost on crash) | Logging, metrics, non-critical |
| CLIENT_ACKNOWLEDGE | Medium | At-least-once (manual ack) | Business events needing explicit confirmation |
| SESSION_TRANSACTED | Lowest | Exactly-once (within session) | Financial, ordering, anything requiring atomicity |

**Production recommendation:** SESSION_TRANSACTED for business queues, AUTO for telemetry.

---

## Broker-Side Tuning

### Classic — KahaDB

```xml
<kahaDB directory="${activemq.data}/kahadb"
        journalMaxFileLength="32mb"
        enableJournalDiskSyncs="false"
        checkpointInterval="5000"/>
```

| Parameter | Default | Tuned | Effect |
|---|---|---|---|
| journalMaxFileLength | 32mb | 32mb | Larger = fewer file rotations, better sequential I/O |
| enableJournalDiskSyncs | true | **false** | Disables fsync per write. 2-5x throughput gain. **TEST ONLY — data loss on crash** |
| checkpointInterval | 5000 | 5000 | How often KahaDB flushes index to disk (ms) |

**Production:** Keep `enableJournalDiskSyncs=true`. The throughput hit is the price of durability.

### Classic — JDBC/PostgreSQL

```xml
<bean id="postgres-ds" class="org.apache.commons.dbcp2.BasicDataSource">
  <property name="maxTotal" value="50"/>
  <property name="initialSize" value="5"/>
  <property name="poolPreparedStatements" value="true"/>
  <property name="testOnBorrow" value="true"/>
</bean>
```

| Parameter | Default | Tuned | Effect |
|---|---|---|---|
| maxTotal | 8 | 50 | DBCP2 connection pool size. Must exceed concurrent producer+consumer threads |
| poolPreparedStatements | false | true | Cache prepared statements — avoids re-parsing SQL per message |
| testOnBorrow | false | true | Validates connection before use — prevents stale connection errors after PG restart |

**JDBC is not a performance play.** It exists for HA (shared storage, master election). Our tests show JDBC adds ~2ms avg latency vs KahaDB at 200 msg/sec. The real risk is the **lease-database-locker** — silent lock loss causes zombie master.

### Artemis — Journal

```xml
<journal-type>NIO</journal-type>
<journal-buffer-size>1048576</journal-buffer-size>
<journal-file-size>10M</journal-file-size>
<journal-min-files>2</journal-min-files>
<journal-pool-files>10</journal-pool-files>
```

| Parameter | Default | Tuned | Effect |
|---|---|---|---|
| journal-type | NIO | NIO (Mac) / **ASYNCIO (prod)** | ASYNCIO uses Linux libaio for kernel-bypass I/O. NIO falls back to Java NIO. ASYNCIO is 2-3x faster for writes |
| journal-buffer-size | 490KB | 1MB | Larger buffer = fewer disk flushes. Batches more writes |
| journal-file-size | 10M | 10M | Size per journal file. Larger = fewer file rotations |
| journal-min-files | 2 | 2 | Pre-created journal files. Avoids file creation stall on startup |
| journal-pool-files | -1 | 10 | Reusable file pool. Avoids create/delete churn under load |

**Critical for production:** Set `journal-type` to `ASYNCIO` on Linux x86. Install `libaio` (`yum install libaio` or EKS AMI). This is the single biggest Artemis performance lever.

### Artemis — Address Settings

```xml
<address-setting match="#">
  <address-full-policy>BLOCK</address-full-policy>
  <max-size-bytes>128M</max-size-bytes>
  <page-size-bytes>10M</page-size-bytes>
</address-setting>
```

| Policy | Behavior | Use Case |
|---|---|---|
| BLOCK | Producer blocks when address full | Default. Simple backpressure. Use when producers can tolerate delays |
| PAGE | Overflow to disk | Large backlogs expected. Adds disk I/O but prevents producer blocking |
| DROP | Silently drop messages | Telemetry/metrics where loss is acceptable |
| FAIL | Reject with exception | Producers must handle errors. Use with retry logic |

**Production recommendation:** PAGE for business queues (handle consumer outages gracefully). BLOCK is simpler but dangerous — a slow consumer or produce-only test will halt all producers on that address with no error, just a hang. We hit this at 72K msg/sec in direct broker testing — filled 128MB in under 1 second.

### Artemis — Connection Tuning

```xml
<connection-ttl-override>30000</connection-ttl-override>
<async-connection-execution-enabled>true</async-connection-execution-enabled>
```

| Parameter | Default | Tuned | Effect |
|---|---|---|---|
| connection-ttl-override | 60000 | 30000 | Time before broker closes idle connection. Lower = faster cleanup of dead clients |
| async-connection-execution-enabled | true | true | Process connection operations on separate thread pool. Prevents blocking acceptor threads |

---

## System-Level Tuning

### Docker Compose Memory

```yaml
environment:
  JAVA_OPTS: "-Xms512m -Xmx512m"  # Fixed heap, no GC resize pauses
```

For test containers, 512MB is sufficient. Production Artemis brokers should have 2-4GB heap minimum.

### Transport (Classic)

```
uri="tcp://0.0.0.0:61616?maximumConnections=1000&wireFormat.maxFrameSize=104857600&wireFormat.maxInactivityDuration=30000"
```

| Parameter | Default | Tuned | Effect |
|---|---|---|---|
| maximumConnections | 1000 | 1000 | Max concurrent TCP connections |
| wireFormat.maxFrameSize | 100MB | 100MB | Max message size. Must accommodate largest message + headers |
| wireFormat.maxInactivityDuration | 30s | 30s | Heartbeat timeout. Too low = false disconnects. Too high = slow dead-client detection |

### System Usage (Classic)

```xml
<systemUsage>
  <memoryUsage limit="256 mb"/>
  <storeUsage limit="512 mb"/>
  <tempUsage limit="1 gb"/>
</systemUsage>
```

- **memoryUsage**: Broker pauses producers when exceeded. Size to expected in-flight messages
- **storeUsage**: KahaDB/JDBC disk limit. Broker stops accepting when full
- **tempUsage**: For non-persistent messages. Size generously or switch to persistent

---

## What We Learned

1. **The broker is not the bottleneck** — Artemis CORE does 77K msg/sec direct. The app layer (HTTP + Spring + JMS client + Docker networking) is the ceiling
2. **Connection pooling is table stakes** — 27% p95 improvement on native client just from adding `pooled-jms`
3. **Classic-looks-faster is an illusion** — The monolith-sim (Java 8, Spring Boot 2.7) has lower per-request overhead than the microservice-sim (Java 21, Spring Boot 3.4). This is app stack overhead, not broker speed
4. **Address-full-policy BLOCK is a trap for produce-only tests** — With no consumers, queue fills 128MB and blocks all producers. Use PAGE for throughput testing
5. **`ha=false&useTopologyForLoadBalancing=false`** — Required for standalone Artemis CORE clients. Without it, client waits 60s for cluster topology that never comes
6. **OpenWire on Artemis buffers 2x memory** — 480KB/msg vs 247KB on Classic. Tune prefetch accordingly
7. **JDBC adds minimal latency** — ~2ms avg overhead vs KahaDB. The migration reason is reliability (zombie master), not performance
8. **NIO vs ASYNCIO matters in production** — Docker on Mac ARM uses NIO. Production x86 Linux should always use ASYNCIO with libaio
9. **At 50 msg/sec, all paths are sub-7ms p95** — the broker choice doesn't matter for typical enterprise workloads. Choose based on operational characteristics (HA, monitoring, protocol support)
10. **Docker Desktop networking adds overhead** — The port-forwarding proxy is the real ceiling for app-level tests, not the broker or the app

---

## Quick Reference: Tuning Profiles

### Latency-Optimized (real-time, sub-10ms target)
- Connection pool: 20 connections, 500 sessions
- Prefetch: 10-50 (low, fair dispatch)
- Ack mode: AUTO_ACKNOWLEDGE
- Artemis: ASYNCIO, 1MB journal buffer, BLOCK policy

### Throughput-Optimized (batch processing, max msg/sec)
- Connection pool: 50 connections, 500 sessions
- Prefetch: 1000 (high, bulk push)
- Ack mode: AUTO_ACKNOWLEDGE
- Artemis: ASYNCIO, 1MB journal buffer, PAGE policy
- Classic: enableJournalDiskSyncs=false (**test only**)

### Reliability-Optimized (financial, zero message loss)
- Connection pool: 10 connections
- Prefetch: 1 (one-at-a-time, manual ack)
- Ack mode: SESSION_TRANSACTED
- Artemis: ASYNCIO, journal-datasync=true, BLOCK policy
- Classic: enableJournalDiskSyncs=true, JDBC with lease-database-locker

---

## Platform Notes

- **Mac M-series (ARM)**: NIO only. ASYNCIO requires libaio (Linux x86). Functional behavior identical, I/O throughput differs
- **Docker Desktop**: DNS flakes can cause build failures. Restart Docker Desktop to resolve
- **EKS production**: Use ASYNCIO, mount EBS gp3 volumes for journal, set IOPS provisioning for JDBC PostgreSQL
