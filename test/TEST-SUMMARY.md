# ActiveMQ Migration Test Environment

## Docker Services

| Container | Image | Host Port | Purpose |
|---|---|---|---|
| `postgres` | postgres:16-alpine | 5432 | JDBC backend for Classic |
| `classic-broker` | apache/activemq-classic:5.18.6 | 61616, 8161 | Classic with KahaDB (file store) |
| `classic-jdbc-broker` | custom (Classic + PostgreSQL driver) | 61618, 8163 | Classic with JDBC/PostgreSQL (mirrors prod) |
| `artemis-broker` | apache/activemq-artemis:latest | 61617, 8162 | Artemis (migration target) |
| `monolith-classic` | monolith-sim (Java 8, OpenWire) | 8081 | App → Classic KahaDB |
| `monolith-classic-jdbc` | monolith-sim (Java 8, OpenWire) | 8084 | App → Classic JDBC |
| `monolith-artemis` | monolith-sim (Java 8, OpenWire) | 8083 | App → Artemis OpenWire compat |
| `microservice-artemis` | microservice-sim (Java 21, native) | 8082 | App → Artemis native client |
| `k6` (profile: k6) | grafana/k6 | - | Load testing |

## Test Apps

### monolith-sim (Java 8, Spring Boot 2.7.18, activemq-client 5.16.7)
- Simulates the production monolith stuck on Java 8
- Connects via OpenWire protocol (same as prod)
- Three instances pointing at different brokers for A/B/C comparison

### microservice-sim (Java 21, Spring Boot 3.4.5, artemis-jms-client 2.53.0)
- Simulates microservices after migration to native Artemis client
- Uses `jakarta.jms` (not `javax.jms`)
- Consumer window size configurable via `CONSUMER_WINDOW_SIZE`

## Test Suite

Each app runs the same 6 test categories via REST endpoints:

| Test | What It Validates | Endpoint |
|---|---|---|
| Small message | 1KB TextMessage + 4 property types (string, int, long, boolean) | `POST /test/small-message` |
| Large message | BytesMessage at 100KB, 1MB, 5MB, 10MB with SHA-256 integrity check | `POST /test/large-message` |
| Transaction commit | 10 messages in transacted session, commit, verify all 10 arrive | `POST /test/transaction-commit` |
| Transaction rollback | 10 messages in transacted session, rollback, verify 0 arrive | `POST /test/transaction-rollback` |
| Prefetch | 50 messages x 10KB, measures heap usage during consumption | `POST /test/prefetch` |
| Request/reply | Temp queue round-trip with JMSReplyTo, correlation ID, cleanup verification | `POST /test/request-reply` |

## Results (2026-04-15)

| Test Suite | Backend | Tests | Result |
|---|---|---|---|
| Monolith → Classic KahaDB | KahaDB (file) | 9 | **All PASS** |
| Monolith → Classic JDBC | PostgreSQL | 9 | **All PASS** |
| Monolith → Artemis (OpenWire) | Artemis journal | 9 | **8 PASS, 1 FAIL** |
| Microservice → Artemis (native) | Artemis journal | 6 | **All PASS** |

**Total: 32/33 passed**

### Known Failure: OpenWire temp queue request/reply on Artemis

```
Cannot publish to a deleted Destination: temp-queue://ID:...
```

The OpenWire client creates a temp queue on connection A. When the responder on connection B tries to send the reply, Artemis treats the temp queue as already deleted. This is a behavioral difference in how Artemis manages temp queue visibility across connections vs Classic.

- Passes on Classic (KahaDB and JDBC)
- Passes on Artemis with the native client
- Fails only on Artemis via the OpenWire compatibility layer

**Impact:** Only relevant if the monolith uses JMS request/reply with temporary queues. Search the codebase for `createTemporaryQueue` or `setJMSReplyTo` to determine if this applies.

### Prefetch Heap Comparison

| Path | Heap Delta (50 x 10KB msgs) | Est. Memory Per Message |
|---|---|---|
| Classic KahaDB | 12.1 MB | 247 KB |
| Classic JDBC | 10.8 MB | 221 KB |
| Artemis (OpenWire) | 23.4 MB | 480 KB |
| Artemis (native) | ~0 MB | 18 KB |

The OpenWire compat layer on Artemis buffers ~2x more memory per message than Classic. The native Artemis client is extremely efficient. For PDF-heavy workloads, tune prefetch accordingly.

## k6 Load Tests

| Script | Purpose |
|---|---|
| `k6/smoke-test.js` | Health checks + single message per path (validates environment) |
| `k6/throughput-test.js` | 10 msg/sec x 30s across all 3 paths, compares p95 latency |
| `k6/large-message-stress.js` | 1MB messages, 2 VUs x 5 iterations per path |

### Throughput Results (30s sustained, 10 msg/sec per path)

| Path | p95 Latency | Avg |
|---|---|---|
| Classic KahaDB | 15ms | 9.8ms |
| Classic JDBC/PostgreSQL | 15ms | 10.2ms |
| Artemis (OpenWire) | 12ms | 7.7ms |
| Artemis (native) | 16ms | 11.1ms |

All 4 paths: 0% failure rate, 1203 total iterations.

## Usage

```bash
cd test

# Run all compatibility tests
./run-tests.sh

# Quick mode (skip large message tests)
./run-tests.sh --quick

# Force rebuild images after code changes
./run-tests.sh --build

# Include k6 load tests
./run-tests.sh --k6

# Run k6 scripts individually
docker compose --profile k6 run --rm k6 run /scripts/smoke-test.js
docker compose --profile k6 run --rm k6 run /scripts/throughput-test.js
docker compose --profile k6 run --rm k6 run /scripts/large-message-stress.js

# Access broker consoles
# Classic KahaDB: http://localhost:8161/admin  (admin/admin)
# Classic JDBC:   http://localhost:8163/admin  (admin/admin)
# Artemis:        http://localhost:8162/console (admin/admin)

# Inspect PostgreSQL JDBC tables
psql -h localhost -U activemq -d activemq
# Tables: activemq_msgs, activemq_acks, activemq_lock

# Stop everything
docker compose down

# Stop and clean up volumes + images
docker compose down -v --rmi local
```

## PostgreSQL JDBC Store

### Schema (`activemq_msgs`)

| Column | Type |
|---|---|
| id | bigint |
| container | varchar(250) |
| msgid_prod | varchar(250) |
| msgid_seq | bigint |
| expiration | bigint |
| msg | bytea |
| priority | bigint |
| xid | varchar(250) |

### Diagnostic Queries

```sql
-- Check master lock holder
SELECT * FROM activemq_lock;

-- Message counts per queue
SELECT container, COUNT(*) FROM activemq_msgs GROUP BY container;

-- Pending acks
SELECT * FROM activemq_acks;

-- Large messages in store
SELECT id, container, LENGTH(msg) AS bytes FROM activemq_msgs ORDER BY LENGTH(msg) DESC LIMIT 10;
```

**Note:** `activemq_msgs` count is typically 0 during normal operation — messages are consumed immediately after production. Non-zero counts indicate consumer lag or unconsumed messages.

## Notes

- Docker runs NIO (not ASYNCIO) on Mac M-series ARM chips. Functional behavior is identical; only I/O throughput differs. ASYNCIO with libaio is for prod x86 EKS nodes.
- Results are saved to `test/results/` with timestamps on each run.
- The JDBC broker config (`classic-jdbc/activemq.xml`) includes the lease-database-locker — the same mechanism that causes "zombie master" failures in production when the JDBC lock is lost silently.
