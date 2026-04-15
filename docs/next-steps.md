# ActiveMQ Artemis Migration - Review Findings

**Reviewed**: 2026-04-14  
**Updated**: 2026-04-15  
**Environment Context**: EKS 1.34, amd64/x86_64, us-east-2, 2 AZs, ~100 queues, PII data, large messages (PDFs)

---

## Executive Summary

**Green**: Architecture is sound. All 18 Helm templates implemented and rendering cleanly. broker.xml HA group assignment fixed (per-ordinal via init container). Test environment validated (32/33 pass). Performance benchmarked (77K msg/sec direct, sub-7ms p95 at app level).

**Yellow**: Operational readiness gaps remain before production. ESO backend undecided, alerting rules not implemented, Grafana dashboard not built, runbooks incomplete.

**Red**: No blockers for dev deployment. Prod blocked on ESO backend decision + cert-manager ClusterIssuer.

---

## 1. COMPLETED (Previously Blockers)

All items that previously blocked dev deployment have been resolved.

- ~~1.1 Helm chart templates missing~~ — **DONE**. All 18 templates implemented, rendering cleanly for all envs.
- ~~1.2 broker.xml HA group assignment~~ — **DONE**. Init container resolves `__HA_GROUP__`, `__HOSTNAME__`, `__ORDINAL__` per pod via sed. `voteOnReplicationFailure` now configurable in values.yaml.
- ~~1.3 StorageClass template~~ — **DONE**. `storageclass.yaml` implemented, conditional on `broker.storage.createStorageClass`.
- ~~1.4 JMX exporter config~~ — **DONE**. `configmap-jmx-exporter.yaml` implemented with Artemis JMX pattern rules.
- ~~1.5 EC2 client connectivity~~ — **DONE**. NLB approach selected. `service-nlb.yaml` implemented, conditional on `broker.nlb.enabled`. Migration guide documents NLB DNS pattern.
- ~~1.6 Namespace parameterization~~ — **DONE**. Templates use `{{ .Release.Namespace }}`.

---

## 2. PRE-PRODUCTION (Needed before prod, not for dev/staging)

These let you run in dev/staging but must be complete before prod deployment.

### 2.1 External Secrets Operator Backend Decision (CRITICAL - M)

**Gap**: Plan says "SSM or Vault TBD" (line 36, 606). Prod values reference it but backend undefined.

**Why it matters**: Prod secrets cannot be provisioned. Hard blocker for prod go-live.

**Decision criteria**:
- **SSM**: Simpler, AWS-native, no infra to manage. Good if no existing Vault.
- **Vault**: Better if already deployed for other secrets. Centralized audit, dynamic secrets, versioning.

**Recommendation**: SSM unless Vault already exists and is mature.

**Action**:
1. Choose backend
2. Create ClusterSecretStore CR (one-time, cluster-wide)
3. Provision secrets in backend (`/artemis/prod/admin-password`, `/artemis/prod/tls-keystore-password`, `/artemis/prod/tls-truststore-password`)
4. Update prod values with correct `secretStoreRef.name`

**Effort**: M (1-2 days including IAM role setup for ESO)

---

### 2.2 cert-manager ClusterIssuer (HIGH - S)

**Gap**: Prod values reference `issuerRef.name: internal-ca` (line 28 in ns1-prod.yaml). Does this ClusterIssuer exist?

**Why it matters**: Certificate CR stuck Pending. TLS doesn't work. Prod deployment fails.

**Action**:
- If internal PKI exists: Configure cert-manager ClusterIssuer pointing to it
- If not: Use Let's Encrypt or AWS Private CA

**Effort**: S (4-8 hours if internal PKI exists; M if building new)

---

### 2.3 PodDisruptionBudget Strategy (HIGH - S)

**Gap**: Plan says `minAvailable: 1` per StatefulSet (line 197 in plan.md, line 238 in values.yaml). With 2 live brokers, `minAvailable: 1` allows 1 eviction. But if live-0 and its paired backup-0 are both evicted, you lose group-0 entirely.

**Why it matters**: Node drains during cluster upgrades could take down entire HA groups.

**Recommendation**: 
- `minAvailable: 1` for live StatefulSet (correct)
- `minAvailable: 0` for backup StatefulSet (allows backup eviction without blocking, live remains available)

OR

- Use `maxUnavailable: 1` for both (ensures only 1 pod per StatefulSet unavailable at a time)

**Action**: Decide strategy, update template.

**Effort**: S (1-2 hours)

---

### 2.4 NetworkPolicy Ingress for Console (MEDIUM - M)

**Gap**: Plan shows NetworkPolicy restricting broker ports (lines 667-718 in plan.md) but console ingress rule is `from: []` (line 714), meaning ANY pod can reach 8161.

**Why it matters**: Admin console exposed to entire cluster. Not PII-compliant if console can leak queue names or message metadata.

**Action**: Restrict console ingress to:
- ALB ingress controller pods (for health checks)
- Admin jump box / bastion pods (if applicable)
- Or remove console NetworkPolicy rule and rely on Ingress auth (ALB + OIDC, or basic auth)

**Effort**: M (4-8 hours including testing)

---

### 2.5 Alerting Rules (HIGH - M)

**Gap**: Plan lists alert thresholds (lines 477-488 in plan.md) but no PrometheusRule manifests exist.

**Why it matters**: Prod incidents go undetected. You find out when users complain.

**Action**: Create PrometheusRule CR with alerts for:
- Queue depth > 10K for 5 min
- DLQ depth > 0
- Consumer count = 0 on active queue
- Broker CPU > 70% for 10 min
- Journal disk > 70%
- Replication lag > 5 sec

**Effort**: M (1-2 days including AlertManager routing config)

---

### 2.6 Grafana Dashboard (MEDIUM - M)

**Gap**: Plan mentions dashboard (line 838 in plan.md, enabled in prod values line 96-99) but no dashboard JSON exists.

**Why it matters**: Ops team flying blind. Capacity planning impossible.

**Action**: Build dashboard with panels for:
- Queue depth per queue
- Throughput (enqueue/dequeue rate)
- Broker CPU/memory
- Disk usage
- Connection count
- DLQ depth
- Replication lag
- Large message count

**Effort**: M (1-2 days)

---

### 2.7 Runbook / Playbooks (HIGH - L)

**Gap**: Partial operational documentation exists. `docs/recovery.md` covers tiered recovery (pod crash, node failure, AZ outage), EBS volume expansion procedure, and producer failover URL. Remaining gaps are operational playbooks for day-to-day scenarios.

**Why it matters**: On-call engineers need step-by-step procedures beyond DR. Mean time to recovery increases without them.

**Action**: Document procedures for:
- Manual broker scale-up (increase replicas)
- ~~EBS volume expansion~~ (done — `docs/recovery.md`)
- Failover testing
- DLQ triage and replay
- Certificate rotation
- Secret rotation
- Backup/restore (journal + large-messages)
- ~~Disaster recovery (AZ failure)~~ (done — `docs/recovery.md`)

**Effort**: L (3-5 days)

---

### 2.8 Load Testing Validation (CRITICAL - L)

**Gap**: Plan references `docs/load-testing-guide.md` (line 1006) which now exists with test scenarios and scripts, but load tests have not been executed yet.

**Why it matters**: You don't know if the architecture performs at scale. Prod is the first real test. Unacceptable risk.

**Action**: 
1. Baseline current ActiveMQ Classic (throughput, latency, failover time)
2. Validate Artemis dev environment matches or exceeds Classic baseline
3. Staging: Run full scenario suite (lines 1029-1036 in plan.md)
4. Prod: 2x peak load + 24-hour soak test before cutover

**Effort**: L (2 weeks including test development + infrastructure)

---

### 2.9 Migration Cutover Plan (CRITICAL - M)

**Gap**: No documented procedure for switching traffic from Classic to Artemis.

**Why it matters**: Downtime, message loss, or dual-feed issues during cutover.

**Options**:
1. **Blue/Green** (recommended): Run both Classic and Artemis, switch producer/consumer configs, drain Classic, decommission.
2. **Big Bang**: Stop Classic, start Artemis, hope for the best (high risk).
3. **Incremental**: Move queue-by-queue (complex, long timeline).

**Recommendation**: Blue/Green with dual-feed for 24 hours, then cut Classic.

**Action**: Document step-by-step cutover procedure including rollback plan.

**Effort**: M (2-3 days)

---

### 2.10 IAM Role for Service Account (MEDIUM - S)

**Gap**: If using SSM for secrets, ESO needs IAM permissions. ServiceAccount annotation missing.

**Why it matters**: ExternalSecret stuck Pending. Secrets not synced.

**Action**: 
1. Create IAM role with `ssm:GetParameter` on `/artemis/*`
2. Annotate ServiceAccount with `eks.amazonaws.com/role-arn`

**Effort**: S (2-4 hours)

---

## 3. DAY-2 OPERATIONS (Needed after go-live)

These improve operability after initial deployment.

### 3.1 EBS Volume Monitoring (MEDIUM - S)

**Gap**: No alerting on EBS IOPS or throughput utilization (mentioned in plan line 482 but not implemented).

**Why it matters**: Disk throttling causes latency spikes, message backlog. Hard to diagnose without metrics.

**Action**: Add CloudWatch metrics to Grafana:
- `VolumeReadOps` / `VolumeWriteOps`
- `VolumeThroughputPercentage`
- Alert when >80% for 10 min

**Effort**: S (4-8 hours)

---

### 3.2 DLQ Monitoring Per Queue (HIGH - M)

**Gap**: Plan mentions monitoring DLQ depths per queue (line 280 in plan.md) but no implementation.

**Why it matters**: Poison messages in one queue shouldn't alert for all queues. Need per-queue triage.

**Action**: 
- JMX exporter already exposes per-queue metrics
- Build Grafana panel grouped by `queue` label
- Alert on `artemis_MessageCount{queue=~"DLQ\..*"} > 0` with label routing

**Effort**: M (1-2 days including alert routing)

---

### 3.3 Connection Leak Detection (MEDIUM - M)

**Gap**: ASG-terminated producers leave stale connections. Plan sets `ttl-override: 300000` (5 min) but no alert if connection count anomalies occur.

**Why it matters**: Connection exhaustion blocks new producers. Outage.

**Action**: Alert on `artemis_broker_ConnectionCount > threshold` for sustained period (e.g. >500 for 10 min).

**Effort**: M (1 day)

---

### 3.4 Journal Compaction Tuning (MEDIUM - M)

**Gap**: Journal compaction settings are defaults (lines 47-48 in values.yaml). No monitoring of compaction events.

**Why it matters**: Excessive compaction causes CPU spikes. Insufficient compaction wastes disk.

**Action**: 
- Log compaction events (Artemis audit log)
- Dashboard panel for journal file count over time
- Tune `compactMinFiles` / `compactPercentage` based on observed behavior

**Effort**: M (1-2 days)

---

### 3.5 Large Message Cleanup Policy (HIGH - M)

**Gap**: Large messages (PDFs) stream to disk. Plan assumes consumers drain them, but if consumers fail, large-messages directory grows unbounded.

**Why it matters**: Disk fills, broker crashes, outage.

**Action**: 
- Set `large-messages` directory size limit or retention policy
- Alert on `artemis_large_message_pending` (if metric exists) or disk usage in that directory
- Consider lifecycle policy: delete large messages >7 days old

**Effort**: M (1-2 days)

---

### 3.6 Slow Consumer Alerting (MEDIUM - S)

**Gap**: Plan configures slow consumer detection (line 83-86 in values.yaml) but policy is `NOTIFY` (log only). No alerting.

**Why it matters**: Slow consumers cause backlog, eventually block producers via BLOCK policy. Silent degradation.

**Action**: 
- Parse Artemis logs for slow consumer warnings
- Alert on log pattern or expose as metric
- Optionally change policy to `KILL` in prod after validating thresholds

**Effort**: S (4-8 hours)

---

### 3.7 Backup and Restore Testing (CRITICAL - L)

**Gap**: `docs/recovery.md` documents tiered recovery scenarios and EBS volume expansion, but no automated EBS snapshot backup/restore procedure or formal restore testing exists.

**Why it matters**: Recovery from simultaneous live+backup loss (both volumes in a group) is untested. Automated backup schedules are not configured.

**Action**:
1. Document EBS snapshot backup procedure (can use K8s VolumeSnapshot + CSI driver)
2. Test restore to new cluster
3. Validate message integrity post-restore
4. Automate backup schedule (daily snapshots, 30-day retention)

**Effort**: L (1 week)

---

### 3.8 Consumer HPA Tuning (MEDIUM - M)

**Gap**: Consumer auto-scaling via Prometheus Adapter + HPA is out of scope for this chart but consumer chart config not included in this review.

**Why it matters**: Consumers scale incorrectly → backlog or wasted resources.

**Action**: 
- Review consumer HPA configuration (Prometheus Adapter + HPA per app chart)
- Validate queue depth thresholds match SLOs
- Load test consumer scaling behavior

**Effort**: M (owned by consumer app teams, coordinate)

---

### 3.9 Cost Monitoring (LOW - S)

**Gap**: Plan estimates cost savings (~$486/mo → $33-175/mo) but no monitoring to validate.

**Why it matters**: EBS costs, data transfer, compute could exceed estimates.

**Action**: Tag all Artemis resources with `app:artemis`, monitor in AWS Cost Explorer. Compare actual vs projected.

**Effort**: S (2-4 hours)

---

## 4. FUTURE IMPROVEMENTS (Nice to have)

These can wait until after successful prod deployment.

### 4.1 S3 Claim Check Pattern (MEDIUM - L)

**Gap**: Plan defers this (line 1049). Current approach stores full PDFs in large-messages directory on EBS.

**Why it matters**: EBS cost, disk I/O, backup size all increase with PDF volume.

**Action**: 
- Producer uploads PDF to S3, sends S3 key as message payload
- Consumer downloads from S3
- Artemis never sees PDF bytes

**Effort**: L (requires producer/consumer code changes)

---

### 4.2 Istio Ambient Mode (LOW - M)

**Gap**: Planned for future (line 1050). Currently using NetworkPolicy.

**Why it matters**: Defense in depth, mTLS between all pods, better observability (L7 metrics).

**Action**: 
- Deploy Istio ambient in cluster
- Add DestinationRule for Artemis (long-lived connections, `idleTimeout: 0s`)
- Replace NetworkPolicy with AuthorizationPolicy

**Effort**: M (Istio deployment is cluster-wide, coordinate with platform team)

---

### 4.3 Third AZ (MEDIUM - M)

**Gap**: 2-AZ deployment means `quorum-size: 1` (vulnerable to split-brain edge cases). Plan notes this (line 1054).

**Why it matters**: In network partition, both sides could promote. Quorum voting with 3 AZs prevents this.

**Action**: 
- Add us-east-2c to EKS node groups
- Increase `broker.replicas.live: 3`, `broker.replicas.backup: 3`
- Set `quorumSize: 2`

**Effort**: M (1-2 days)

---

### 4.4 Message Expiry Policies (MEDIUM - M)

**Gap**: Plan says retention is "forever" (line 1080), will define after analysis.

**Why it matters**: Unbounded storage growth, eventually broker crashes.

**Action**: 
- Analyze queue patterns (some queues may have natural expiry, e.g. "order must process within 24h")
- Set `expiryDelay` per address-setting override
- Monitor ExpiryQueue depth

**Effort**: M (requires business input on SLAs)

---

### 4.5 Additional Cluster Groups (LOW - M)

**Gap**: Prod starts with 2 live brokers (Group 0, Group 1). Plan mentions scaling to 4+ groups as throughput grows.

**Why it matters**: Horizontal scaling beyond current broker count.

**Action**: 
- When sustained load exceeds 2-broker capacity, add Group 2 / Group 3 by increasing static broker count
- Update static connectors, cert SANs, redeploy

**Effort**: M (1-2 days)

---

### 4.6 LDAP/AD Integration (LOW - M)

**Gap**: Plan asks "JAAS auth — just properties file or need LDAP integration?" (line 1066).

**Why it matters**: Central user management, audit compliance.

**Action**: 
- If required, configure Artemis JAAS LoginModule for LDAP
- Update broker.xml with JAAS config

**Effort**: M (1-2 days)

---

### 4.7 Multi-Region DR (LOW - L)

**Gap**: No cross-region disaster recovery.

**Why it matters**: us-east-2 region failure = full outage.

**Action**: 
- Deploy Artemis in secondary region (e.g. us-west-2)
- Cross-region replication (requires custom solution, Artemis doesn't support this natively)
- Or accept region-level risk and rely on RTO for redeployment

**Effort**: L (complex, likely not worth it unless business criticality demands)

---

## 5. ARCHITECTURAL RISKS TO REVISIT

### 5.1 Large Message Handling Without Backpressure (MEDIUM)

**Risk**: PDFs stream to `large-messages` directory on disk. If consumers fall behind (crash, slow processing), directory fills, disk exhausts, broker crashes.

**Why it matters**: Current design has no backpressure on large message disk usage (separate from journal `maxDiskUsage: 90%`).

**Recommendation**: 
- Monitor large-messages directory size explicitly
- Set alert threshold (e.g. >50% of EBS volume)
- OR implement S3 claim check pattern (defer to future, but should be prioritized if PDF volume is high)

**Trade-off**: Adds monitoring overhead vs. risk of undetected disk exhaustion.

---

### 5.2 Two-AZ Quorum Size (MEDIUM)

**Risk**: `quorum-size: 1` means a single backup can promote itself. In network partition (AZ-a and AZ-b can't communicate), both sides might promote. Quorum voting with 2 AZs and `quorum-size: 1` doesn't prevent split-brain.

**Why it matters**: Rare but catastrophic. Duplicate message processing, data integrity issues.

**Mitigation**: Plan correctly identifies this (line 1054) and recommends 3rd AZ. Until then, accept risk or implement external quorum coordinator (complex).

**Recommendation**: 
- Accept risk in dev/staging
- For prod, either:
  - Deploy 3rd AZ (best)
  - OR document split-brain recovery procedure (manual intervention, stop one side, merge journals)

---

### 5.3 Connection Management for ASG Producers (LOW)

**Risk**: EC2 ASG producers terminate without cleanly closing connections. Broker holds stale connections for `ttl-override: 300000` (5 min). During rapid ASG scale-in, connection pool could exhaust.

**Why it matters**: New producers blocked, throughput drops.

**Mitigation**: Plan sets `ttl-override` and `maxConnections: 1000`. Likely sufficient, but needs validation.

**Recommendation**: Load test ASG scale-in (e.g. 100 instances → 10 instances in 2 minutes) and confirm connection count doesn't exceed threshold.

---

## 6. TECHNICAL DEBT / DESIGN DECISIONS TO DOCUMENT

### 6.1 Why Quorum Size = 1?

**Documented in plan**: 2-AZ deployment (line 239). Good. But see architectural risk 5.2 above.

---

### 6.2 Why Fixed Broker Count Instead of Dynamic?

Brokers are statically sized. The documented burst (~100K msg/hr = ~28 msg/sec) is well within 2-broker capacity. Consumers are the scaling bottleneck, not brokers. Scaling consumers (stateless) is simpler and safer than scaling brokers (stateful with journal data).

---

### 6.3 Why Custom Helm Chart Instead of Community Chart?

**Documented in plan** (line 804). Rationale is sound. No action needed.

---

## 7. SUMMARY TABLE

| Category | Item | Priority | Effort | Blocker For |
|---|---|---|---|---|
| ~~**Completed**~~ | ~~Helm templates~~ | ~~CRITICAL~~ | ~~L~~ | ~~Dev deployment~~ |
| | ~~broker.xml HA group fix~~ | ~~CRITICAL~~ | ~~S~~ | ~~Dev deployment~~ |
| | ~~StorageClass~~ | ~~MEDIUM~~ | ~~S~~ | ~~Dev deployment~~ |
| | ~~JMX exporter config~~ | ~~MEDIUM~~ | ~~S~~ | ~~Observability~~ |
| | ~~EC2 client connectivity (NLB)~~ | ~~MEDIUM~~ | ~~S~~ | ~~Producer/consumer traffic~~ |
| | ~~Namespace parameterization~~ | ~~LOW~~ | ~~S~~ | ~~Multi-env~~ |
| **Pre-Prod** | ESO backend decision | CRITICAL | M | Prod secrets |
| | cert-manager ClusterIssuer | HIGH | S | Prod TLS |
| | PDB strategy | HIGH | S | Prod HA |
| | Console NetworkPolicy | MEDIUM | M | Prod security |
| | Alerting rules | HIGH | M | Prod ops |
| | Grafana dashboard | MEDIUM | M | Prod ops |
| | Runbooks | HIGH | L | Prod ops |
| | Load testing | CRITICAL | L | Prod cutover |
| | Migration cutover plan | CRITICAL | M | Prod cutover |
| | IAM role for ESO | MEDIUM | S | Prod secrets |
| **Day-2** | EBS monitoring | MEDIUM | S | — |
| | DLQ per-queue alerts | HIGH | M | — |
| | Connection leak detection | MEDIUM | M | — |
| | Journal compaction tuning | MEDIUM | M | — |
| | Large message cleanup | HIGH | M | — |
| | Slow consumer alerting | MEDIUM | S | — |
| | Backup/restore testing | CRITICAL | L | — |
| | Consumer HPA tuning | MEDIUM | M | — |
| | Cost monitoring | LOW | S | — |
| **Future** | S3 claim check | MEDIUM | L | — |
| | Istio ambient | LOW | M | — |
| | Third AZ | MEDIUM | M | — |
| | Message expiry policies | MEDIUM | M | — |
| | Additional cluster groups | LOW | M | — |
| | LDAP integration | LOW | M | — |
| | Multi-region DR | LOW | L | — |

---

## 8. RECOMMENDED NEXT STEPS (Prioritized)

### ~~Phase 1: Unblock Dev Deployment~~ — COMPLETE
All Helm templates implemented, broker.xml HA fixed, StorageClass/JMX/NLB/namespace done. Ready for dev deploy.

### Phase 2: Pre-Production Readiness (3 weeks)
1. **Decide ESO backend** (SSM recommended) and implement (M)
2. Create IAM role for ESO service account (S)
3. Create/configure cert-manager ClusterIssuer (S)
4. Review and fix PDB strategy (S)
5. Build Grafana dashboard (M)
6. Implement PrometheusRule alerts (M)
7. Harden console NetworkPolicy (M)
8. Write runbooks (L)
9. Develop and execute load tests in staging (L)

### Phase 3: Production Cutover (2 weeks)
1. Document migration cutover plan (M)
2. Execute cutover to prod (coordinate with teams)
3. 2x peak load + 24-hour soak test
4. Monitor for 1 week, iterate on alerts/dashboards

### Phase 4: Day-2 Hardening (ongoing)
1. DLQ per-queue monitoring (M)
2. Large message cleanup policy (M)
3. Backup/restore testing (L)
4. EBS monitoring (S)
5. Connection leak detection (M)
6. Journal compaction tuning (M)

### Phase 5: Future Improvements (3-6 months post-launch)
1. S3 claim check pattern (if PDF volume is high)
2. Third AZ (if split-brain risk is unacceptable)
3. Message expiry policies (once business SLAs are defined)

---

## 9. FILES STILL NEEDED

```
charts/artemis/templates/              # All 18 templates EXIST
docs/
├── runbooks/
│   ├── failover.md                    # PRE-PROD
│   ├── scale-brokers.md               # PRE-PROD
│   ├── dlq-triage.md                  # PRE-PROD
│   └── certificate-rotation.md        # PRE-PROD
├── migration-cutover.md               # PRE-PROD
└── adr/
    └── 001-eso-backend-choice.md      # NOW
monitoring/
├── prometheus-rules.yaml              # PRE-PROD
└── grafana-dashboard.json             # PRE-PROD
```

---

## FINAL VERDICT

**Overall Assessment**: Strong architectural foundation, all Helm templates implemented and rendering, broker.xml HA fixed. Primary remaining risk is operational readiness for prod.

**Go/No-Go for Dev**: GO. All templates exist, render cleanly, init container resolves per-pod config.

**Go/No-Go for Prod**: NO-GO until pre-production checklist complete (ESO, certs, load testing, runbooks, alerts).

**Estimated Timeline to Prod-Ready**: 5-7 weeks (3 weeks pre-prod + 2 weeks cutover/validation).
