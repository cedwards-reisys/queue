# AWS Storage Comparison for ActiveMQ Artemis Journal (us-east-2)

## Workload Profile
- **Pattern**: Write-heavy, fsync-heavy journal append operations
- **I/O Mode**: ASYNCIO (libaio) with direct I/O - bypasses page cache
- **Sync**: syncNonTransactional enabled - every message fsyncs
- **Compliance**: PII data requiring persistence
- **Critical Metric**: IOPS and latency > throughput (small record writes)

---

## Storage Options Comparison

| Option | IOPS (Baseline) | IOPS (Max) | Throughput (Baseline) | Throughput (Max) | Latency | Cost (100Gi/mo) | KMS Encryption |
|--------|----------------|------------|----------------------|------------------|---------|----------------|----------------|
| **gp3** (default) | 3,000 | 16,000 | 125 MB/s | 1,000 MB/s | Single-digit ms | $8.00 | Yes |
| **gp3** (provisioned 10K IOPS) | 10,000 | 16,000 | 250 MB/s | 1,000 MB/s | Single-digit ms | $78.00¹ | Yes |
| **io2** | 500 per GiB (50,000) | 64,000² | 500 MB/s | 1,000 MB/s | Sub-millisecond | $656.50³ | Yes |
| **io2 Block Express** | 1,000 per GiB (100,000) | 256,000 | 1,000 MB/s | 4,000 MB/s | Sub-millisecond | $1,313.00⁴ | Yes |
| **io1** | 50 per GiB (5,000) | 64,000 | 500 MB/s | 1,000 MB/s | Single-digit ms | $656.50³ | Yes |
| **Instance Store (i3en.2xlarge)** | 400K+ (4x NVMe) | 400K+ | 8 GB/s | 8 GB/s | < 100 µs | $0 (in instance)⁵ | No (ephemeral) |
| **Instance Store (i4i.2xlarge)** | 500K+ (4x NVMe) | 500K+ | 10 GB/s | 10 GB/s | < 50 µs | $0 (in instance)⁵ | No (ephemeral) |

**Notes:**
1. gp3 provisioned: $8.00 (storage) + $70.00 (7,000 extra IOPS @ $0.01/IOPS)
2. io2 max: 64,000 IOPS for volumes < 256 GiB; higher volumes get more
3. io2/io1: $0.125/GB-month + $0.065/provisioned IOPS-month (50,000 IOPS assumed)
4. io2 Block Express: $0.125/GB-month + $0.119/provisioned IOPS-month (100,000 IOPS assumed)
5. Instance cost: i3en.2xlarge = $730/mo, i4i.2xlarge = $820/mo (on-demand, us-east-2)

---

## Artemis Journal Pros/Cons

### gp3 (Default 3K IOPS)
**Pros:**
- Cost-effective for dev/staging
- Elastic scaling without instance changes
- KMS encryption for PII compliance
- Predictable baseline performance

**Cons:**
- 3K IOPS may bottleneck under message spikes with fsync
- Latency higher than io2/instance store (single-digit ms vs sub-ms)
- Credit exhaustion risk if burst beyond baseline

**Artemis Fit:** Adequate for low-moderate message rates (<3K msgs/sec with fsync), but likely bottleneck for production.

---

### gp3 (Provisioned 10K IOPS)
**Pros:**
- 3.3x IOPS increase over baseline
- Still significantly cheaper than io2
- No burst/credit mechanics - sustained performance
- KMS encryption

**Cons:**
- Latency still single-digit ms (not sub-ms)
- IOPS ceiling at 16K - limited headroom

**Artemis Fit:** Good balance for moderate-high message rates (<10K msgs/sec). Best cost/performance for most production workloads.

---

### io2
**Pros:**
- Sub-millisecond latency critical for fsync operations
- 50K IOPS at 100Gi (500 IOPS/GiB)
- 99.999% durability SLA
- KMS encryption

**Cons:**
- 8x more expensive than gp3 provisioned
- Overkill IOPS for most Artemis workloads
- Pay for provisioned IOPS whether used or not

**Artemis Fit:** Only justified for extreme low-latency requirements or SLA-driven durability needs. Likely over-provisioned for typical broker.

---

### io2 Block Express
**Pros:**
- Sub-millisecond latency
- 100K IOPS at 100Gi
- 256K IOPS max (future-proof)
- 4 GB/s throughput

**Cons:**
- 16x more expensive than gp3 provisioned
- Requires Nitro instances (EKS likely supports)
- Massive over-provisioning for Artemis journal

**Artemis Fit:** Not recommended unless running ultra-high-volume message broker (>50K msgs/sec sustained with fsync). Financial services HFT use case only.

---

### io1
**Pros:**
- Sub-millisecond latency
- Predictable performance
- KMS encryption

**Cons:**
- Only 5K IOPS at 100Gi (50 IOPS/GiB) - worse than gp3 provisioned
- Same cost as io2 but lower IOPS ratio
- Superseded by io2 (no reason to choose io1)

**Artemis Fit:** Deprecated - use io2 if you need io-class volume.

---

### Instance Store (i3en/i4i Family)
**Pros:**
- 50-100x higher IOPS than EBS (400K-500K)
- Sub-100µs latency (40-50x lower than io2)
- Zero marginal cost (included in instance price)
- Best possible journal performance

**Cons:**
- **Ephemeral** - data lost on instance stop/termination/hardware failure
- No KMS encryption (PII compliance issue)
- Requires Artemis HA replication (min 3-node cluster with sync replication)
- StatefulSet pod evictions = data loss (node upgrades risky)
- EKS node recycling/upgrades require careful orchestration

**Artemis Fit:** Performance is unmatched, but **ephemeral nature conflicts with PII compliance requirements**. Could work with:
- 3+ broker cluster with `minReplicas=2` quorum writes
- Live-backup to S3 or EBS snapshots (defeats performance gain)
- Accepting message loss risk during node failures (likely unacceptable for PII)

**Verdict:** Not recommended for PII compliance workload despite performance. Risk > reward.

---

## fsync Performance Analysis

With `syncNonTransactional: true`, every message commit triggers fsync. This makes **IOPS the primary bottleneck**, not throughput.

**Effective Message Rate Limits (fsync-bound):**
- gp3 (3K IOPS): ~3,000 msgs/sec max
- gp3 (10K IOPS): ~10,000 msgs/sec max
- io2 (50K IOPS): ~50,000 msgs/sec max
- Instance Store (400K+ IOPS): ~400K+ msgs/sec max

**Reality Check:** Most Artemis deployments see <5K msgs/sec sustained. If you're exceeding 10K msgs/sec, consider:
1. Batching/transaction commits (reduce fsync frequency)
2. Disabling syncNonTransactional for non-critical flows
3. Async journaling for non-PII messages

---

## Recommended Configuration by Environment

### Development (20 GiB)
**Choice:** gp3 default (3,000 IOPS / 125 MB/s)
- **Cost:** $1.60/month
- **Rationale:** Dev workloads rarely exceed 3K msgs/sec. Baseline sufficient.
- **Config:**
  ```yaml
  storageClassName: gp3
  storage: 20Gi
  # No IOPS provisioning needed
  ```

---

### Staging (50 GiB)
**Choice:** gp3 with 6,000 provisioned IOPS / 250 MB/s
- **Cost:** $34.00/month ($4 storage + $30 IOPS)
- **Rationale:** Test production-like message rates with headroom. 2x baseline IOPS for load testing.
- **Config:**
  ```yaml
  storageClassName: gp3
  storage: 50Gi
  iops: "6000"
  throughput: "250"
  ```

---

### Production (100 GiB)
**Choice:** gp3 with 10,000 provisioned IOPS / 250 MB/s
- **Cost:** $78.00/month
- **Rationale:** 
  - 10K msgs/sec sustained capacity (3.3x baseline)
  - Headroom for spikes without latency degradation
  - 8x cheaper than io2 with sufficient performance
  - KMS encryption meets PII compliance
  - Can scale to 16K IOPS if needed (additional $60/mo)
- **Config:**
  ```yaml
  storageClassName: gp3
  storage: 100Gi
  iops: "10000"
  throughput: "250"
  ```

**When to Upgrade to io2:**
- Message rate consistently >15K msgs/sec
- p99 latency SLA <1ms required
- Budget allows 8x storage cost increase

---

## Final Recommendation

**Standard Production: gp3 with 10K provisioned IOPS**
- Meets PII compliance (KMS encryption)
- Handles 10K msgs/sec sustained fsync load
- Cost-effective at $78/mo vs $656+ for io2
- Upgrade path to 16K IOPS if needed

**High-Performance Production (if required): io2**
- Only if message rate >15K msgs/sec sustained
- Sub-millisecond latency requirement
- Budget supports $656/mo storage cost

**Avoid:**
- gp3 baseline (3K IOPS) for production - will bottleneck
- io2 Block Express - massive over-provisioning
- io1 - superseded by io2
- Instance store - ephemeral storage conflicts with PII compliance

---

## Monitoring & Validation

Post-deployment, monitor these CloudWatch metrics:
- `VolumeReadOps` / `VolumeWriteOps` - track IOPS usage vs provisioned
- `VolumeQueueLength` - sustained >1 indicates IOPS saturation
- `BurstBalance` - should stay at 100% with provisioned IOPS (no bursting)

**Artemis metrics to correlate:**
- Journal append latency (track p50, p99, p999)
- Message persistence rate (msgs/sec)
- Disk sync time (fsync duration)

If `VolumeQueueLength` consistently >1 or fsync latency spikes, increase provisioned IOPS to next tier (12K or 16K).

---

## Cost Summary (Production 100Gi)

| Option | Monthly Cost | Cost per 1K IOPS |
|--------|--------------|------------------|
| gp3 (baseline) | $8.00 | $2.67 |
| gp3 (10K IOPS) | $78.00 | $7.80 |
| io2 (50K IOPS) | $656.50 | $13.13 |
| io2 Block Express | $1,313.00 | $13.13 |
| i4i.2xlarge (500K IOPS) | $820.00 | $1.64 |

**Winner:** gp3 provisioned offers best cost/performance for persistent PII workload.
