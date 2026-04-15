# ActiveMQ Classic → Artemis Migration Guide

## Overview

Migrate from self-managed ActiveMQ Classic (3x EC2, JDBC/PostgreSQL) to ActiveMQ Artemis on EKS. Zero application code changes for the monolith, dependency swap for microservices.

## Application Landscape

| App | Java | Current Client | Migration Path | Code Changes |
|---|---|---|---|---|
| **Monolith** (consumer/producer) | 8 | `activemq-client` (OpenWire) | URL swap only | None — config change only |
| **Microservices** (consumer/producer) | 21+ | `activemq-client` (OpenWire) | Swap to `artemis-jms-client` | Dependency + import change |

## Client Configuration

### Monolith (Java 8 — OpenWire compatibility)

No code changes. Artemis accepts OpenWire connections via its compatibility layer. Only the broker URL changes.

**Before (Classic — hardcoded EC2 IPs):**
```properties
broker.url=failover:(tcp://10.0.1.50:61616,tcp://10.0.1.51:61616,tcp://10.0.1.52:61616)
```

**After (Artemis — NLB DNS):**
```properties
broker.url=failover:(tcp://ns1.artemis.prod.example.io:61616)?maxReconnectAttempts=-1&reconnectDelay=1000&reconnectDelayExponent=2&maxReconnectDelay=30000
```

The NLB routes to healthy live broker pods. Only one URL needed — no broker list to maintain.

### Microservices (Java 21+ — Native Artemis client)

**Dependency swap:**
```xml
<!-- Remove -->
<dependency>
    <groupId>org.apache.activemq</groupId>
    <artifactId>activemq-client</artifactId>
</dependency>

<!-- Add -->
<dependency>
    <groupId>org.apache.activemq</groupId>
    <artifactId>artemis-jms-client</artifactId>
    <version>2.53.0</version>
</dependency>
```

**Connection factory — same class name, different package:**
```java
// Before (Classic)
import org.apache.activemq.ActiveMQConnectionFactory;

// After (Artemis)
import org.apache.activemq.artemis.jms.client.ActiveMQConnectionFactory;
```

**Spring Boot with `spring-boot-starter-artemis`:**
```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-artemis</artifactId>
</dependency>
```

```yaml
# application.yml
spring:
  artemis:
    broker-url: failover:(tcp://ns1.artemis.prod.example.io:61616)?maxReconnectAttempts=-1&reconnectDelay=1000
    user: ${ARTEMIS_USER}
    password: ${ARTEMIS_PASSWORD}
```

### Connection Endpoints by Client Location

| Client | Endpoint | DNS |
|---|---|---|
| EC2 ASG (monolith) | NLB | `ns1.artemis.prod.example.io:61616` |
| EC2 ASG (microservices) | NLB | `ns1.artemis.prod.example.io:61616` |
| EKS pods (microservices) | ClusterIP | `artemis-live.ns1.svc.cluster.local:61616` |

---

## OpenWire Compatibility — Known Quirks

The monolith will connect to Artemis via OpenWire (Classic's native protocol). Artemis has an OpenWire compatibility layer, but there are behavioral differences that must be tested.

### 1. Large Message Handling (PDFs)

**The issue:** Classic and Artemis handle large messages differently.

- Classic stores all messages in the JDBC database regardless of size
- Artemis streams messages larger than `largeMessages.minSize` (100KB) to a separate disk directory, bypassing the journal and JVM heap

**What could go wrong:**
- PDF content corruption during OpenWire → Artemis internal format conversion
- Different behavior for `BytesMessage` vs `TextMessage` with large payloads
- Client-side prefetch buffer may not be sized for large messages

**How to test:**
```bash
# 1. Produce a range of PDF sizes through the monolith
#    Use actual production PDFs if possible, not synthetic data
#    Test: 100KB, 500KB, 1MB, 5MB, 10MB, 25MB

# 2. Consume and verify
#    - File size matches
#    - Content hash matches (SHA-256 before send vs after receive)
#    - No truncation
#    - Message properties preserved

# 3. Check Artemis large-messages directory
kubectl exec artemis-live-0 -n ns1 -- ls -la /var/lib/artemis/data/large-messages/
# Should contain files during transit, empty after consumption
```

**Artemis setting to verify:**
```yaml
broker:
  largeMessages:
    minSize: 102400   # 100KB — anything above this streams to disk
```

If the average PDF is smaller than 100KB, it goes through the normal journal path. Adjust `minSize` based on actual PDF size distribution from `amq-analyze.sh`.

### 2. Transaction Semantics

**The issue:** JMS transactions should be identical between Classic and Artemis, but edge cases exist.

- Classic XA transactions use the JDBC store as the transaction log
- Artemis XA transactions use the journal as the transaction log
- Transaction timeout behavior may differ

**What could go wrong:**
- Transactions that span multiple queues may behave differently
- `SESSION_TRANSACTED` commit/rollback timing differences under load
- XA recovery after broker failover — different recovery protocol

**How to test:**
```
1. Transacted send + receive (happy path)
   - Send 100 messages in a transaction, commit
   - Verify all 100 arrive
   - Send 100, rollback — verify none arrive

2. Transaction under failover
   - Start transaction, send 50 messages
   - Kill live broker mid-transaction
   - Verify: uncommitted messages do NOT appear on any queue
   - Verify: client gets exception, can retry

3. Multi-queue transaction (if used)
   - Send to queue-A and queue-B in same transaction
   - Commit — verify both queues receive
   - Rollback — verify neither receives

4. XA transactions (if used)
   - Verify XA recovery works after broker restart
   - Check for orphaned prepared transactions:
     kubectl exec artemis-live-0 -n ns1 -- \
       /var/lib/artemis/bin/artemis data print --journal \
       | grep -i "prepared\|xa"
```

**Key question:** Does the monolith use `SESSION_TRANSACTED`, `XA`, or neither? This determines how much transaction testing is needed.

### 3. Prefetch Settings

**The issue:** Classic and Artemis have different default prefetch (consumer buffer) sizes, which directly impacts throughput and memory.

| Setting | Classic Default | Artemis Default | Impact |
|---|---|---|---|
| Queue prefetch | 1000 | 1000 (CORE), varies (OpenWire) | Consumer buffers this many messages in memory |
| Topic prefetch | 32766 | 1000 | Much less aggressive in Artemis |

**What could go wrong:**
- If Classic prefetch is tuned high and Artemis uses a lower default, consumers may appear slower (more broker round-trips)
- If prefetch is too high with large PDFs, consumer OOM (1000 x 5MB = 5GB in consumer heap)
- Uneven message distribution across consumers when prefetch is high

**How to test:**
```
1. Baseline consumer throughput
   - 10 consumers on 1 queue, 10K messages, measure drain rate
   - Compare Classic vs Artemis

2. Large message prefetch stress
   - Set prefetch to 100
   - Send 100 x 5MB PDFs
   - Monitor consumer heap usage
   - Consumer should NOT OOM

3. Fair distribution
   - 3 consumers on 1 queue
   - Send 300 messages
   - Verify roughly even distribution (100 each, not 300 to one consumer)
```

**Tuning on the Artemis side (acceptor config):**

Prefetch for OpenWire clients is controlled by the client, not the broker. But you can limit it broker-side:

```xml
<!-- In broker.xml acceptor, append to URL params -->
?openwire.prefetchPolicy.queuePrefetch=100
```

**Recommended starting point for PDF workloads:** Prefetch of 10-50 instead of 1000. With 5MB PDFs, `prefetch=1000` means each consumer buffers up to 5GB. Start low, increase based on throughput needs.

**Client-side override (in monolith config):**
```properties
# Classic client prefetch config
broker.url=failover:(tcp://ns1.artemis.prod.example.io:61616)?jms.prefetchPolicy.queuePrefetch=50
```

### 4. Temp Queue Behavior (Request/Reply)

**The issue:** If any application uses JMS request/reply with temporary queues, behavior differs between Classic and Artemis.

Classic request/reply pattern:
```java
// Producer creates temp queue for reply
TemporaryQueue replyTo = session.createTemporaryQueue();
message.setJMSReplyTo(replyTo);
producer.send(message);

// Consumer reads request, sends reply to replyTo
MessageConsumer replyConsumer = session.createConsumer(replyTo);
Message reply = replyConsumer.receive(30000);
```

**What could go wrong:**
- Temp queue names differ between Classic and Artemis — if anything parses the name, it breaks
- Temp queues in Classic are tied to the connection — Artemis same, but cleanup timing may differ
- OpenWire temp queue creation over the compatibility layer may be slower
- If the request goes to live-0 but the reply consumer is on live-1 (via NLB routing), the temp queue only exists on live-0

**How to test:**
```
1. Basic request/reply
   - Send request with replyTo temp queue
   - Verify reply arrives within timeout
   - Verify temp queue is cleaned up after connection closes

2. Request/reply under load
   - 50 concurrent request/reply threads
   - Verify no orphaned temp queues accumulate
   - Check: kubectl exec artemis-live-0 -n ns1 -- \
       /var/lib/artemis/bin/artemis queue stat --url tcp://localhost:61616 \
       | grep -c "temp"

3. Request/reply across failover
   - Send request, kill live broker before reply
   - Client should get timeout exception
   - Temp queue should be cleaned up on new live
```

**Key question:** Does the monolith or any microservice use request/reply (temp queues)? If not, skip this testing entirely.

### 5. Message Property Handling

**The issue:** Not commonly documented, but worth testing.

- Classic allows non-standard property types and names
- Artemis is stricter about JMS spec compliance
- Properties starting with `JMS` or `JMSX` are reserved

**How to test:**
```
1. Send a message with all custom properties your apps use
2. Consume and verify every property is preserved (name, type, value)
3. Pay attention to:
   - Nested properties
   - Binary properties
   - Properties with special characters in names
   - Large string properties
```

---

## Migration Phases

### Phase 1: Deploy and Validate (Dev)

**Duration:** 1 week

```
1. Deploy Artemis to dev namespace (1 live, no HA)
2. Run amq-analyze.sh against Classic to capture:
   - Queue inventory
   - Message rates per queue
   - Message size distribution (especially PDF sizes)
   - Peak vs off-peak patterns
3. Point monolith dev instance → Artemis (URL change only)
4. Run OpenWire compatibility tests:
   - Send/receive small messages ✓
   - Send/receive PDFs (all sizes) ✓
   - Transaction commit/rollback ✓
   - Verify consumer ACK mode behavior ✓
5. Update one microservice with artemis-jms-client dependency
6. Deploy to dev, verify it connects and processes messages
```

**Go/No-Go criteria:**
- All message types produce and consume correctly
- PDF content integrity verified (hash comparison)
- No orphaned temp queues (if request/reply is used)
- Transaction semantics match Classic behavior

### Phase 2: HA and Performance (Staging)

**Duration:** 2 weeks

```
1. Deploy Artemis to staging (1 live + 1 backup, HA enabled)
2. Point monolith staging → Artemis
3. Swap microservice clients to artemis-jms-client
4. Run load tests (k6 scenarios):
   - Baseline throughput (Scenario 1)
   - Large message / PDF throughput (Scenario 2)
   - Burst absorption (Scenario 3)
   - Failover under load (Scenario 6)
5. Test failover:
   - Kill live pod, verify backup promotes
   - Verify monolith reconnects via NLB
   - Verify microservices reconnect
   - Verify zero message loss (produced == consumed)
6. Run for 1 week under normal staging traffic
7. Monitor:
   - Queue depth trends
   - Disk usage growth rate
   - Consumer lag
   - DLQ accumulation
   - Replication sync status
```

**Go/No-Go criteria:**
- Failover completes in <30s
- Zero message loss during failover
- PDF integrity maintained through failover
- No memory leaks over 1 week
- Disk usage growth rate confirms 200Gi is sufficient

### Phase 3: Production Migration

**Duration:** 2 weeks (gradual cutover)

**Pre-cutover checklist:**
```
[ ] Artemis prod deployed (2 live + 2 backup)
[ ] TLS enabled, certs issued
[ ] NetworkPolicy applied
[ ] NLB healthy, DNS CNAME resolving
[ ] Monitoring: ServiceMonitor, alerts, Grafana dashboard
[ ] Recovery runbook reviewed by team
[ ] Classic left running (rollback target)
[ ] Communication sent to stakeholders
```

**Cutover strategy — queue by queue, not big bang:**

```
Week 1: Low-risk queues
  1. Identify 5-10 low-volume, non-critical queues
  2. Drain those queues on Classic (stop producers, let consumers finish)
  3. Reconfigure producers for those queues → Artemis (URL change)
  4. Reconfigure consumers for those queues → Artemis
  5. Monitor for 2 days

Week 2: Remaining queues
  6. If Week 1 is clean, migrate remaining queues in batches
  7. Save highest-volume / PDF-heavy queues for last
  8. Once all queues migrated, Classic handles zero traffic
  9. Keep Classic running for 2 weeks (rollback safety net)
  10. Decommission Classic
```

**Why not dual-write (produce to both Classic and Artemis)?**
- Doubles message volume
- Consumers need to be pointed at one or the other anyway
- Complicates exactly-once semantics
- Queue-by-queue migration is simpler and equally safe

### Phase 4: Post-Migration (2 weeks after cutover)

```
1. Monitor steady-state for 2 weeks
   - Peak noon traffic patterns
   - Weekend batch handling
   - DLQ accumulation trends
   - Disk usage growth rate
2. Tune based on data:
   - Prefetch settings
   - Journal buffer size
   - Provisioned IOPS (check VolumeQueueLength)
   - Storage size (expand if growing faster than expected)
3. Decommission Classic infrastructure
   - Stop Classic brokers
   - Snapshot RDS (keep 30 days for audit)
   - Terminate EC2 instances
   - Delete RDS instance
4. Update monitoring:
   - Remove Classic alerts
   - Verify Artemis alerts are firing correctly
```

---

## Rollback Plan

If Artemis fails in production, rollback to Classic:

```
1. Classic is still running (do not decommission until 2 weeks post-migration)
2. Reconfigure producers → Classic broker URLs (revert config change)
3. Reconfigure consumers → Classic
4. Messages in-flight on Artemis will be lost unless consumed first
5. Drain Artemis queues before switching if possible
```

**Rollback takes:** ~30 minutes (config changes + app redeploy)

**Rollback window:** 2 weeks post-migration. After that, Classic is decommissioned.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| OpenWire PDF corruption | Low | High | Test with real PDFs in Phase 1. Hash comparison before/after. |
| Prefetch OOM with large messages | Medium | Medium | Start with prefetch=50. Monitor consumer heap. |
| Monolith can't connect (OpenWire compat) | Low | High | Tested in Phase 1. Rollback to Classic is immediate. |
| Transaction behavior difference | Low | High | Explicit transaction testing in Phase 1. |
| NLB health check flapping | Low | Medium | TCP health check on 61616 is reliable. Tune unhealthy threshold if needed. |
| Temp queue leak | Low | Low | Monitor with `queue stat`. Only relevant if apps use request/reply. |
| Classic decommissioned too early | Medium | High | Mandatory 2-week bake period before decommission. |
| Weekend batch overwhelms Artemis | Low | Medium | 200Gi storage, 10K provisioned IOPS. Monitor first weekend closely. |

---

## Information to Gather Before Starting

These are not blockers — migration can begin in dev without them. But answers improve planning:

| Question | Why It Matters | How to Get It |
|---|---|---|
| What ACK mode does the monolith use? | `AUTO_ACKNOWLEDGE` loses messages on failover | Check Spring JMS config or `@JmsListener` annotations |
| Does any app use request/reply (temp queues)? | Different behavior in Artemis | Search codebase for `createTemporaryQueue` or `setJMSReplyTo` |
| Does any app use XA transactions? | Needs specific failover testing | Search for `XAConnectionFactory` or `JtaTransactionManager` |
| What's the average PDF size? | Drives `largeMessages.minSize` and prefetch tuning | `amq-analyze.sh` or check S3/storage where PDFs originate |
| Which queues carry PDFs? | These get tested first and most thoroughly | Application config or queue naming conventions |
| Current Classic prefetch setting | Need to match or intentionally change | Check `activemq.xml` or client connection URL params |
| Queue naming conventions | Helps plan migration order and address-setting overrides | `amq-analyze.sh` or Classic admin console |
