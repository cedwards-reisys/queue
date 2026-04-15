# ActiveMQ Load Testing Guide

Compare performance between current ActiveMQ Classic (EC2/JDBC) and new Artemis (EKS) setup. Validate performance and failover behavior under load.

---

## Tooling

### Why Not JMeter

JMeter with the JMS plugin works but is heavyweight, requires a GUI for test design, and is painful to run in K8s. For message broker testing, purpose-built tools are simpler and more accurate.

### Tools Used

| Tool | Purpose | Layer | Runs on |
|---|---|---|---|
| **k6** | Drive HTTP endpoints on Spring Boot producers — tests full stack (app → JMS → broker → consumer) | Application | K8s Job, local, or Grafana Cloud k6 |
| **`artemis perf`** | Built into Artemis CLI — raw broker throughput/latency testing | Broker | K8s Job or local |

#### Why Both

| Approach | What it measures | When to use |
|---|---|---|
| **k6 → Spring Boot HTTP → JMS → Broker** | End-to-end latency, full stack bottlenecks, real-world behavior | Scenarios 3-5 (burst, mixed, auto-scaling) |
| **`artemis perf` → Broker directly** | Raw broker throughput ceiling, wire protocol performance | Scenarios 1-2 (baseline, large message comparison) |

k6 gives you realistic load patterns with ramping, stages, and thresholds. `artemis perf` gives you the raw broker numbers for apples-to-apples Classic vs Artemis comparison.

`artemis perf` speaks CORE protocol natively and OpenWire — works against both Classic and Artemis.

---

## Test Scenarios

### Scenario 1: Baseline Throughput

Measure max messages/sec for small messages. Pure broker throughput, no consumer processing time.

| Parameter | Value |
|---|---|
| Message size | 1 KB |
| Producers | 10 concurrent |
| Consumers | 10 concurrent |
| Duration | 5 minutes |
| Persistence | Enabled |
| ACK mode | Client ACK |

### Scenario 2: Large Message Throughput

Measure impact of PDF-sized messages on broker performance.

| Parameter | Value |
|---|---|
| Message size | 1 MB, 5 MB, 10 MB |
| Producers | 5 concurrent |
| Consumers | 5 concurrent |
| Duration | 5 minutes per size |
| Persistence | Enabled |
| ACK mode | Client ACK |

### Scenario 3: Burst Absorption

Simulate 100K message burst, measure time to drain.

| Parameter | Value |
|---|---|
| Message size | 1 KB |
| Phase 1 (produce) | 100K messages, max rate, 0 consumers |
| Phase 2 (consume) | Start consumers, measure drain time |
| Consumers | 5, then 10, then 20 (test scaling effect) |

### Scenario 4: Mixed Workload

Simulate realistic traffic — mostly small messages with occasional large ones.

| Parameter | Value |
|---|---|
| Message size | 90% @ 1 KB, 10% @ 5 MB |
| Producers | 10 concurrent |
| Consumers | 10 concurrent |
| Duration | 10 minutes |
| Queues | 10 (round-robin across queues) |

### Scenario 5: Consumer Auto-Scale Validation (Artemis Only)

Verify HPA scales consumers under load and scales back down.

| Parameter | Value |
|---|---|
| Message size | 1 KB |
| Producers | 20 concurrent (sustained) |
| Consumers | Start with HPA min (2), observe scale-up |
| Duration | 15 minutes |
| Observe | Consumer pod count, queue depth, drain rate |
| Then | Stop producers, observe scale-down |

### Scenario 6: Failover Under Load

Verify zero message loss during broker failure.

| Parameter | Value |
|---|---|
| Message size | 1 KB |
| Producers | 10 concurrent (persistent, sync) |
| Consumers | 10 concurrent (client ACK) |
| During test | Kill live broker pod |
| Measure | Messages lost, failover time, consumer reconnect time |
| Verify | Total produced == total consumed |

### Scenario 7: Cluster Rebalancing (Artemis Only)

Verify message redistribution works across cluster groups.

| Parameter | Value |
|---|---|
| Setup | Consumers connected to live-0 only |
| Producers | Send to live-1 only |
| Observe | Messages redistribute from live-1 to live-0 where consumers are |
| Measure | Redistribution latency, throughput |

---

## Metrics to Capture

### Per Test Run

| Metric | How |
|---|---|
| **Produce rate** (msgs/sec) | `artemis perf` output |
| **Consume rate** (msgs/sec) | `artemis perf` output |
| **Latency** (p50/p95/p99) | `artemis perf` output |
| **CPU/Memory** (broker) | Prometheus / `kubectl top` |
| **Disk I/O** (IOPS, throughput) | CloudWatch EBS metrics or `iostat` |
| **Queue depth over time** | Prometheus `artemis_MessageCount` |
| **Consumer pod count** (scaling tests) | `kubectl get pods` over time |
| **Messages produced vs consumed** | Compare totals — must match for zero-loss validation |
| **GC pauses** | JMX exporter / New Relic |
| **Replication lag** | Prometheus (Artemis only) |

### Comparison Report Template

| Metric | Classic (EC2/JDBC) | Artemis (EKS/Journal) | Delta |
|---|---|---|---|
| Max throughput (1KB) | ___ msgs/sec | ___ msgs/sec | __% |
| Max throughput (5MB) | ___ msgs/sec | ___ msgs/sec | __% |
| Latency p50 (1KB) | ___ ms | ___ ms | __% |
| Latency p95 (1KB) | ___ ms | ___ ms | __% |
| Latency p99 (1KB) | ___ ms | ___ ms | __% |
| 100K burst drain time | ___ sec | ___ sec | __% |
| Broker CPU at max load | __% | __% | — |
| Broker memory at max load | ___ MB | ___ MB | — |
| GC pause max | ___ ms | ___ ms | — |
| Failover time | ___ sec | ___ sec | — |
| Messages lost on failover | ___ | ___ | — |

---

## k6 Test Scripts

### Scenario 1: Baseline Throughput (Full Stack)

```javascript
// k6/scenarios/baseline.js
import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const publishLatency = new Trend('publish_latency_ms');

const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-arrival-rate',
      rate: 100,                    // 100 msgs/sec
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 20,
      maxVUs: 50,
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<500', 'p(99)<1000'],
    'errors': ['rate<0.01'],
  },
};

export default function () {
  const payload = JSON.stringify({
    id: `msg-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
    data: 'x'.repeat(1024),       // 1KB payload
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  publishLatency.add(res.timings.duration);
  check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
}
```

### Scenario 3: Burst Absorption (100K Messages)

```javascript
// k6/scenarios/burst.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const sent = new Counter('messages_sent');
const errorRate = new Rate('errors');

const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';
const TARGET_MSGS = parseInt(__ENV.TARGET_MSGS || '100000');

export const options = {
  scenarios: {
    burst: {
      executor: 'shared-iterations',
      iterations: TARGET_MSGS,
      vus: 50,                    // 50 concurrent producers
      maxDuration: '30m',
    },
  },
  thresholds: {
    'errors': ['rate<0.01'],
  },
};

export default function () {
  const payload = JSON.stringify({
    id: `burst-${__ITER}-${__VU}`,
    data: 'x'.repeat(1024),
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  sent.add(1);
}
```

### Scenario 4: Mixed Workload (Small + Large Messages)

```javascript
// k6/scenarios/mixed.js
import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('errors');
const smallLatency = new Trend('small_msg_latency_ms');
const largeLatency = new Trend('large_msg_latency_ms');

const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';
const LARGE_PAYLOAD = 'x'.repeat(5 * 1024 * 1024);   // 5MB
const SMALL_PAYLOAD = 'x'.repeat(1024);                // 1KB

export const options = {
  scenarios: {
    mixed: {
      executor: 'constant-arrival-rate',
      rate: 50,
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 20,
      maxVUs: 50,
    },
  },
  thresholds: {
    'errors': ['rate<0.01'],
  },
};

export default function () {
  const isLarge = Math.random() < 0.1;   // 10% large messages
  const queue = `test-queue-${Math.floor(Math.random() * 10)}`;

  const payload = JSON.stringify({
    id: `mixed-${Date.now()}-${__VU}`,
    queue: queue,
    data: isLarge ? LARGE_PAYLOAD : SMALL_PAYLOAD,
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages/${queue}`, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: isLarge ? '30s' : '10s',
  });

  check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);

  if (isLarge) {
    largeLatency.add(res.timings.duration);
  } else {
    smallLatency.add(res.timings.duration);
  }
}
```

### Scenario 5: Auto-Scale Validation (Ramp Up, Sustain, Ramp Down)

```javascript
// k6/scenarios/autoscale.js
import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');
const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';

export const options = {
  scenarios: {
    autoscale: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 100,
      stages: [
        { target: 10, duration: '1m' },     // warm up
        { target: 200, duration: '2m' },     // ramp to heavy load — should trigger scale-up
        { target: 200, duration: '5m' },     // sustain — consumers should stabilize
        { target: 10, duration: '2m' },      // ramp down — should trigger scale-down
        { target: 10, duration: '5m' },      // cool down — observe scale-down
      ],
    },
  },
  thresholds: {
    'errors': ['rate<0.05'],
  },
};

export default function () {
  const payload = JSON.stringify({
    id: `scale-${Date.now()}-${__VU}`,
    data: 'x'.repeat(1024),
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });

  check(res, { 'status 200': (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
}
```

### Scenario 6: Failover Under Load

```javascript
// k6/scenarios/failover.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const messagesSent = new Counter('messages_sent');
const messagesAcked = new Counter('messages_acked');
const errorRate = new Rate('errors');
const publishLatency = new Trend('publish_latency_ms');

const BASE_URL = __ENV.PRODUCER_URL || 'http://producer-app:8080';

// Failover test: sustained load for 10 minutes.
// During the test, kill a broker pod externally (manual or via chaos tool).
// Compare messages_sent vs messages consumed (check consumer metrics after test).
// Zero message loss is the target.
export const options = {
  scenarios: {
    failover: {
      executor: 'constant-arrival-rate',
      rate: 50,
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
  },
  thresholds: {
    'errors': ['rate<0.05'],           // allow 5% during failover window
    'http_req_duration': ['p(95)<2000', 'p(99)<5000'],
  },
};

export default function () {
  const msgId = `failover-${Date.now()}-${__VU}-${__ITER}`;

  const payload = JSON.stringify({
    id: msgId,
    data: 'x'.repeat(1024),
    persistent: true,
    timestamp: new Date().toISOString(),
  });

  const res = http.post(`${BASE_URL}/api/messages`, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '10s',
  });

  messagesSent.add(1);
  publishLatency.add(res.timings.duration);

  const success = check(res, {
    'status 200': (r) => r.status === 200,
    'not timeout': (r) => r.timings.duration < 10000,
  });

  if (success) {
    messagesAcked.add(1);
  }
  errorRate.add(!success);
}
```

**Running the failover test:**
1. Start the k6 test
2. ~3 minutes in, kill a live broker pod: `kubectl delete pod artemis-live-0 -n ns1`
3. Observe reconnection behavior and error spike
4. After test, compare `messages_sent` (k6 output) vs consumed count (consumer metrics/logs)

### Running k6

```bash
# Local
k6 run --env PRODUCER_URL=http://localhost:8080 k6/scenarios/baseline.js

# Against in-cluster service (port-forward)
kubectl port-forward svc/producer-app 8080:8080 -n ns1
k6 run --env PRODUCER_URL=http://localhost:8080 k6/scenarios/burst.js

# As K8s Job (most accurate — no port-forward overhead)
# Use grafana/k6-operator or a simple Job with the k6 image
kubectl apply -f k6/jobs/baseline-job.yaml -n ns1

# With k6 Cloud / Grafana Cloud k6 (if available)
k6 cloud k6/scenarios/autoscale.js
```

### k6 as K8s Job

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-baseline
  namespace: ns1
spec:
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      containers:
        - name: k6
          image: grafana/k6:latest
          command: ["k6", "run", "/scripts/baseline.js"]
          env:
            - name: PRODUCER_URL
              value: "http://producer-app.ns1.svc:8080"
          volumeMounts:
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: scripts
          configMap:
            name: k6-test-scripts
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/arch: amd64
```

---

## Running Tests — `artemis perf` (Raw Broker Comparison)

### Against Current ActiveMQ Classic

The `artemis perf` tool can connect to Classic via OpenWire. Run from a bastion or EC2 instance with network access to the broker.

```bash
# Download Artemis CLI (just need the binary, not a running broker)
# https://activemq.apache.org/components/artemis/download/
wget https://downloads.apache.org/activemq/activemq-artemis/2.53.0/apache-artemis-2.53.0-bin.tar.gz
tar xzf apache-artemis-2.53.0-bin.tar.gz
export ARTEMIS_HOME=$(pwd)/apache-artemis-2.53.0

# Use the load test script
./scripts/amq-loadtest.sh --target classic --host <classic-broker-host> --port 61616
```

### Against New Artemis on EKS

Run as K8s Jobs in the same namespace for accurate in-cluster measurements.

```bash
# Port-forward for local testing
kubectl port-forward svc/artemis-live 61616:61616 -n ns1

# Or use the load test script pointed at the service
./scripts/amq-loadtest.sh --target artemis --host artemis-live.ns1.svc --port 61616

# Or run as K8s Job (recommended for accurate numbers)
helm install loadtest charts/artemis-loadtest \
  --set broker.host=artemis-live.ns1.svc \
  --set scenario=baseline \
  -n ns1
```

---

## Load Test Helm Chart — `artemis-loadtest`

Runs test scenarios as K8s Jobs. Separate chart from the broker so it can be installed/removed independently.

### Structure

```
charts/artemis-loadtest/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── _helpers.tpl
│   ├── job-producer.yaml
│   ├── job-consumer.yaml
│   └── configmap-scenarios.yaml
```

### How It Works

1. Producer Job: runs `artemis perf producer` with scenario parameters
2. Consumer Job: runs `artemis perf consumer` with matching parameters
3. Both use the same Artemis container image (CLI included)
4. Results written to stdout → captured via `kubectl logs`
5. Jobs auto-clean after completion (`ttlSecondsAfterFinished`)

---

## Pre-Migration Testing Checklist

### Phase 1: Baseline Current System

- [ ] Run Scenario 1 (baseline throughput) against Classic
- [ ] Run Scenario 2 (large messages) against Classic
- [ ] Run Scenario 3 (burst absorption) against Classic
- [ ] Run Scenario 4 (mixed workload) against Classic
- [ ] Record all metrics in comparison template

### Phase 2: Validate New System

- [ ] Deploy Artemis to nonprod (dev namespace)
- [ ] Run Scenarios 1-4 against Artemis (same parameters)
- [ ] Record metrics — compare against Classic baseline
- [ ] Run Scenario 5 (consumer auto-scaling)
- [ ] Run Scenario 6 (failover under load)
- [ ] Run Scenario 7 (cluster rebalancing)

### Phase 3: Staging Validation

- [ ] Deploy Artemis to staging (ns2)
- [ ] Run full scenario suite
- [ ] Confirm performance meets or exceeds Classic baseline
- [ ] Validate failover — zero message loss
- [ ] Validate consumer auto-scaling triggers and stabilizes

### Phase 4: Production Burn-In

- [ ] Deploy Artemis to prod (ns1) — shadow mode or canary
- [ ] Run Scenario 4 (mixed workload) at 2x expected peak
- [ ] Soak test: 24-hour sustained load at expected average
- [ ] Confirm no memory leaks, journal growth, replication lag
