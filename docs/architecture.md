# ActiveMQ Artemis on EKS - Architecture

## Overview

Replaces self-managed ActiveMQ Classic (3x EC2 + PostgreSQL JDBC) with ActiveMQ Artemis 2.53.0 on EKS 1.34 (amd64/x86_64). ASYNCIO journal-based persistence on EBS gp3 volumes with provisioned IOPS. Helm chart with per-environment parameterization deployed via ArgoCD.

## Topology Per Tier

### Dev (ns1) — Single Broker, No HA

```
  ┌──────────┐     ┌──────────────────────────────────────┐
  │ Producers├────►│          EKS Cluster (amd64)         │
  │  (ASG)   │     │                                      │
  └──────────┘     │  ┌────────────────────┐              │
                   │  │   Live Broker 0    │              │
                   │  │   (single AZ)      │              │
  ┌──────────┐     │  │   EBS gp3 20Gi     │              │
  │ Consumers│◄────│  └────────────────────┘              │
  │(EKS/ASG) │     │                                      │
  └──────────┘     └──────────────────────────────────────┘
```

- 1 live pod, no backup, no clustering
- Minimal resources (500m CPU, 1Gi)
- No TLS, no NetworkPolicy, no PDB

### Staging / QA (ns2, ns3) — Replication HA

```
  ┌──────────┐     ┌──────────────────────────────────────────┐
  │ Producers├────►│           EKS Cluster (amd64)            │
  │  (ASG)   │     │                                          │
  └──────────┘     │  us-east-2a          us-east-2b          │
                   │  ┌───────────────┐   ┌───────────────┐   │
                   │  │ Live Broker 0 │──►│Backup Broker 0│   │
                   │  │ EBS gp3 50Gi  │   │ EBS gp3 50Gi  │   │
  ┌──────────┐     │  └───────────────┘   └───────────────┘   │
  │ Consumers│◄────│                                          │
  │(EKS/ASG) │     └──────────────────────────────────────────┘
  └──────────┘
```

- 1 live + 1 backup, cross-AZ replication
- No clustering (single live handles all traffic)
- NetworkPolicy + PDB enabled
- Validates HA failover before prod

### Prod (ns1) — Cluster + Replication HA

```
  ┌──────────┐     ┌─────────────────────────────────────────────────┐
  │ Producers├────►│             EKS Cluster (amd64)                 │
  │  (ASG)   │     │                                                 │
  └──────────┘     │  us-east-2a              us-east-2b             │
                   │  ┌───────────────┐       ┌───────────────┐      │
                   │  │ Live Broker 0 │◄─────►│ Live Broker 1 │      │
                   │  │ EBS gp3 200Gi │cluster│ EBS gp3 200Gi │      │
                   │  └──────┬────────┘       └──────┬────────┘      │
                   │         │ replication            │ replication  │
                   │         ▼                        ▼              │
                   │  ┌───────────────┐       ┌───────────────┐      │
                   │  │Backup Broker 0│       │Backup Broker 1│      │
                   │  │  (us-east-2b) │       │  (us-east-2a) │      │
                   │  └───────────────┘       └───────────────┘      │
                   │                                                 │
  ┌──────────┐     │  ┌───────────────────────────────────────┐      │
  │ Consumers│◄────│  │  Consumer Pods (HPA-scaled)           │      │
  │  (ASG)   │     │  │  Prometheus Adapter + HPA per app     │      │
  └──────────┘     │  └───────────────────────────────────────┘      │
                   └─────────────────────────────────────────────────┘
```

- 2 live + 2 backup, cross-AZ replication + inter-live clustering
- Live/backup pairs always in opposite AZs
- Cluster connection redistributes messages to brokers with active consumers
- TLS (cert-manager), NetworkPolicy, PDB, Grafana dashboard
- Consumers in both EKS (HPA-scaled) and EC2 ASGs

## Environment Tiers

| Dimension | dev (ns1) | staging (ns2) | qa (ns3) | prod (ns1) |
|---|---|---|---|---|
| **AWS Account** | nonprod | nonprod | nonprod | prod |
| **Pods** | 1 live | 1 live + 1 backup | 1 live + 1 backup | 2 live + 2 backup |
| **HA Mode** | none | replication | replication | cluster + replication |
| **Clustering** | off | off | off | on (2-node) |
| **CPU req/limit** | 500m / 1 | 1 / 2 | 1 / 2 | 2 / 4 |
| **Memory req/limit** | 1Gi / 2Gi | 2Gi / 4Gi | 2Gi / 4Gi | 4Gi / 8Gi |
| **JVM Heap (xms/xmx)** | 512m / 1g | 1g / 2g | 1g / 2g | 2g / 4g |
| **Storage** | 20Gi | 50Gi | 50Gi | 200Gi |
| **Journal type** | ASYNCIO | ASYNCIO | ASYNCIO | ASYNCIO |
| **Journal sync (non-tx)** | false | true | true | true |
| **Journal buffer** | 490KB (default) | 490KB (default) | 490KB (default) | 1MB |
| **Journal min/pool files** | 2 / -1 | 2 / -1 | 2 / -1 | 10 / 20 |
| **Journal maxIo** | 500 | 500 | 500 | 500 |
| **EBS IOPS** | 3K (baseline) | 6K (provisioned) | 6K (provisioned) | 10K (provisioned) |
| **EBS throughput** | 125 MB/s | 250 MB/s | 250 MB/s | 250 MB/s |
| **TLS** | off | off | off | on (cert-manager) |
| **NetworkPolicy** | off | on | on | on |
| **PDB** | off | on | on | on |
| **ServiceMonitor** | on (30s) | on (15s) | on (15s) | on (15s) |
| **Grafana Dashboard** | off | off | off | on |

## Configuration Files

```
charts/artemis/
├── values.yaml                        # Base defaults (dev-safe)
└── values/
    ├── nonprod/
    │   ├── ns1-dev.yaml               # Minimal single broker
    │   ├── ns2-staging.yaml           # HA replication, prod-like
    │   └── ns3-qa.yaml                # HA replication, prod-like
    └── prod/
        └── ns1-prod.yaml             # Full cluster + replication
```

Each environment overlay only specifies deltas from the base `values.yaml`. The base is intentionally dev-safe (1 pod, no HA, no TLS, no NetworkPolicy).

## ArgoCD Sync Wave Ordering

Resources deploy in dependency order via sync wave annotations:

| Wave | Resources | Purpose |
|---|---|---|
| -3 | StorageClass, ServiceAccount | Infrastructure prerequisites |
| -2 | Secret / ExternalSecret | Credentials available before cert issuance |
| -1 | Certificate, ConfigMaps (broker, JMX) | Certs issued + configs ready before workloads |
| 0 | Services, NetworkPolicy, PDB | Network plumbing in place |
| 1 | StatefulSet (live), StatefulSet (backup) | Workloads start after all deps |
| 2 | Ingress, ServiceMonitor, Grafana Dashboard | Monitoring + routing after workloads healthy |

## Secrets Management

Three strategies supported (mutually exclusive):

### 1. Helm-Generated Secret (default)
- Chart generates a K8s Secret with `randAlphaNum` passwords
- Suitable for dev/testing only
- Passwords regenerate on each `helm upgrade` unless pinned

### 2. External Secrets Operator (recommended for prod)
```yaml
broker:
  externalSecrets:
    enabled: true
    secretStoreRef:
      name: aws-ssm              # or vault-backend
      kind: ClusterSecretStore
    remoteRefs:
      adminPassword: /artemis/prod/admin-password
      tlsKeystorePassword: /artemis/prod/tls-keystore-password
      tlsTruststorePassword: /artemis/prod/tls-truststore-password
```
- Supports SSM Parameter Store or HashiCorp Vault via ClusterSecretStore
- ESO syncs secrets on `refreshInterval` (default 1h)
- ExternalSecret CR creates the same `<release>-credentials` K8s Secret name
- Sync wave -2 ensures secret exists before workloads

### 3. Pre-existing Secret
```yaml
broker:
  auth:
    existingSecret: my-artemis-credentials
```
- Bring your own Secret — chart references it by name
- You manage the Secret lifecycle

## Storage Architecture

- **StorageClass**: `artemis-gp3-encrypted` with KMS encryption at rest
- **VolumeBindingMode**: `WaitForFirstConsumer` (ensures volume created in same AZ as pod)
- **AccessMode**: `ReadWriteOnce` (one volume per broker pod)
- **Filesystem**: ext4
- Each broker pod gets its own PVC via StatefulSet `volumeClaimTemplates`
- **Provisioned IOPS**: gp3 baseline is 3K IOPS — insufficient for prod fsync workloads. Staging/QA use 6K, prod uses 10K.

```
Broker Pod → PVC → EBS gp3 (KMS encrypted, provisioned IOPS)
  └── /var/lib/artemis/data/
        ├── journal/          # Message journal (ASYNCIO — direct I/O via libaio)
        ├── bindings/         # Address/queue bindings
        ├── paging/           # Overflow when memory full
        └── large-messages/   # Messages > 100KB streamed here
```

### IOPS Sizing Rationale

With `syncNonTransactional: true`, every message commit triggers fsync. IOPS = throughput ceiling.

| Tier | Volume | IOPS | Throughput | Cost/mo | Effective msg/sec ceiling |
|---|---|---|---|---|---|
| dev | 20Gi gp3 | 3,000 (baseline) | 125 MB/s | $1.60 | ~3,000 |
| staging/qa | 50Gi gp3 | 6,000 (provisioned) | 250 MB/s | $34 | ~6,000 |
| prod | 200Gi gp3 | 10,000 (provisioned) | 250 MB/s | $94 | ~10,000 |

**Upgrade path**: gp3 supports up to 16K IOPS. If `VolumeQueueLength > 1` sustained, increase provisioned IOPS. If >16K needed, evaluate io2 (~$656/mo for 50K IOPS).

## TLS Architecture

Enabled in prod for PII compliance:

```
cert-manager (ClusterIssuer)
    │
    ▼
Certificate CR (sync wave -1)
    │
    ▼
K8s TLS Secret (tls.crt, tls.key, ca.crt)
    │
    ▼
init container (PEM → PKCS12 conversion)
    │
    ├── keystore.p12  → acceptor/connector sslEnabled
    └── truststore.p12 → inter-broker mTLS
```

- **Client connections**: TLS (one-way, `needClientAuth=false`)
- **Inter-broker** (cluster + replication): mTLS (`needClientAuth=true`)
- **Certificate SANs**: All pod DNS names + service DNS names
- **Algorithm**: ECDSA P-256
- **Rotation**: Auto-renewed 30 days before expiry

## Networking

| Port | Purpose | Protocol |
|---|---|---|
| 61616 | Client connections (OpenWire/CORE/AMQP) | TCP |
| 61617 | Cluster connections | TCP (CORE) |
| 61618 | Replication | TCP (CORE) |
| 8161 | Admin console | HTTP |
| 9404 | JMX exporter metrics | HTTP |

- **ClusterIP Service** (`artemis-live`): Client-facing, port 61616
- **Headless Services** (`artemis-live-headless`, `artemis-backup-headless`): Pod DNS for clustering/replication
- **Console Service** → ALB Ingress (shared ingress group, HTTPS via ACM cert)
- **NetworkPolicy**: Restricts ingress to labeled clients, inter-broker, prometheus, console

## Observability Pipeline

```
Artemis JMX → JMX Exporter Sidecar → Prometheus (ServiceMonitor)
                                            │
                                  ┌─────────┼─────────┐
                                  ▼                   ▼
                              Grafana            AlertManager
                             Dashboard           (thresholds)
```

Prometheus handles observability (dashboards + alerts).

Key metrics exposed:
- `artemis_MessageCount` (queue depth)
- `artemis_MessagesAdded_total` / `artemis_MessagesAcknowledged_total` (throughput)
- `artemis_ConsumerCount`, `artemis_DeliveringCount`
- `artemis_broker_ConnectionCount`, `artemis_broker_disk_store_usage`
- `artemis_broker_address_memory_usage_pct`, `artemis_broker_replica_sync`

## Scaling Strategy

- **Brokers**: Fixed count, statically sized per environment (set in values). No horizontal auto-scaling
- **Consumers (EKS)**: Prometheus Adapter + HPA scales based on queue depth (managed by each app's Helm chart, not this chart)
- **Consumers (ASG)**: EC2 Auto Scaling policies, connections come/go with instance lifecycle
- **Cluster nodes**: Cluster Autoscaler provisions amd64 nodes as pods demand
- **Producers (ASG)**: ASG-managed EC2, connections managed via `connection-ttl-override` (5 min) to reap stale connections from terminated instances

## Key Design Decisions

| Decision | Rationale |
|---|---|
| ASYNCIO journal (libaio) | amd64/x86_64 — direct I/O bypasses page cache for lower latency |
| Quorum size = 1 | 2-AZ deployment — larger quorum would block failover |
| EBS gp3 (not EFS) | RWO per broker, no shared filesystem overhead |
| No S3 claim check (yet) | Future iteration — native large message streaming (>100KB→disk) handles current needs |
| Static cluster connectors | Fixed broker count, simpler than UDP/JGroups discovery |
| Fixed broker count | Brokers are statically sized — simpler, safer, proven. Consumers scale independently |
| ClusterIP (not NLB) | Broker traffic is internal to EKS — no external TCP exposure needed |
| ALB for console only | HTTP-based, shares existing ALB ingress group |
| Auto-create per-queue DLQs | `DLQ.{queueName}` — 100+ queues, per-queue DLQ isolation |

## Prerequisites

- EKS 1.34+ (amd64 node groups, e.g. m6i, m7i, c6i)
- cert-manager (for TLS in prod)
- External Secrets Operator (for SSM/Vault secret sync)
- Prometheus (for dashboards + alerting)
- Grafana with sidecar provisioner (for dashboard auto-import)
- AWS Load Balancer Controller (for ALB ingress)
- Cluster Autoscaler
- ArgoCD
- artemis-gp3-encrypted StorageClass (chart can create if `broker.storage.createStorageClass: true`)
