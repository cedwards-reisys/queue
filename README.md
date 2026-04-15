# ActiveMQ Artemis on EKS

Migrate from self-managed ActiveMQ Classic (3x EC2, JDBC/PostgreSQL) to ActiveMQ Artemis on EKS with cluster + replication HA.

## Why

- Classic suffers from silent JDBC lock failures (zombie master)
- No observability — unknown message volumes, no alerting
- Vertical scaling doesn't help — bottleneck is PostgreSQL, not broker
- Leverage existing EKS infrastructure to reduce operational overhead

## Current vs Target

| | Current | Target |
|---|---|---|
| **Broker** | ActiveMQ Classic 5.18 | ActiveMQ Artemis 2.53.0 |
| **Persistence** | JDBC/PostgreSQL RDS | ASYNCIO journal on EBS gp3 |
| **HA** | Master/slave via DB lock (unreliable) | Synchronous replication + quorum voting |
| **Infrastructure** | 3x EC2 instances | EKS StatefulSets (2 live + 2 backup) |
| **Cost** | ~$486/mo + ops overhead | ~$33-175/mo |

## Architecture (Prod)

```
                        EKS Cluster (us-east-2)
  ┌──────────────────────────────┬──────────────────────────────┐
  │         us-east-2a           │         us-east-2b           │
  │                              │                              │
  │  ┌────────────────────┐      │      ┌────────────────────┐  │
  │  │  live-0  (group-0) │──────┼repl─▶│ backup-0 (group-0  │  │
  │  │  EBS gp3 200Gi     │      │      │  EBS gp3 200Gi     │  │
  │  └─────────┬──────────┘      │      └────────────────────┘  │
  │            │                 │                              │
  │         cluster              │                              │
  │            │                 │                              │
  │  ┌─────────┴──────────┐      │      ┌────────────────────┐  │
  │  │ backup-1 (group-1) │◀─repl┼──────│  live-1  (group-1) │  │
  │  │  EBS gp3 200Gi     │      │      │  EBS gp3 200Gi     │  │
  │  └────────────────────┘      │      └────────────────────┘  │
  │                              │                              │
  └──────────────────────────────┴──────────────────────────────┘

  ┌──────────┐                                    ┌──────────────┐
  │ Producers│──▶ ClusterIP / NLB ──▶ live pods   │  Consumers   │
  │ (EC2 ASG)│                                    │ (EKS HPA +   │
  └──────────┘                                    │  EC2 ASG)    │
                                                  └──────────────┘
```

- Live/backup pairs always in opposite AZs
- Synchronous replication within each group
- Cluster connection between lives for message redistribution
- Consumers in both EKS (HPA-scaled) and EC2 ASGs

## Environment Tiers

| | dev (ns1) | staging (ns2) | qa (ns3) | prod (ns1) |
|---|---|---|---|---|
| Pods | 1 live | 1+1 | 1+1 | 2+2 |
| HA | off | replication | replication | cluster + replication |
| CPU/Memory | 500m/1Gi | 1/2Gi | 1/2Gi | 2/4Gi |
| Storage | 20Gi | 50Gi | 50Gi | 200Gi |
| EBS IOPS | 3K baseline | 6K | 6K | 10K |
| TLS | off | off | off | on (cert-manager) |
| NetworkPolicy | off | on | on | on |

## Repository Structure

```
.
├── charts/artemis/                    # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml                    # Base defaults (dev-safe)
│   ├── templates/                     # All K8s manifests
│   │   ├── _helpers.tpl               # Naming, labels, broker.xml rendering
│   │   ├── statefulset-live.yaml      # Live broker pods
│   │   ├── statefulset-backup.yaml    # Backup broker pods (conditional)
│   │   ├── configmap-broker.yaml      # broker.xml + bootstrap.xml
│   │   ├── configmap-jmx-exporter.yaml
│   │   ├── secret-credentials.yaml    # Helm-generated (skipped if ESO)
│   │   ├── external-secret.yaml       # ESO integration (conditional)
│   │   ├── certificate.yaml           # cert-manager (conditional)
│   │   ├── storageclass.yaml          # gp3-encrypted (conditional)
│   │   ├── service-clusterip.yaml     # Client connections
│   │   ├── service-headless.yaml      # Inter-broker discovery
│   │   ├── service-console.yaml       # Admin console
│   │   ├── service-nlb.yaml           # EC2 client access (conditional)
│   │   ├── ingress-console.yaml       # ALB ingress (conditional)
│   │   ├── networkpolicy.yaml         # Access control (conditional)
│   │   ├── pdb-live.yaml              # PodDisruptionBudget
│   │   ├── pdb-backup.yaml            # PDB for backups (conditional)
│   │   ├── serviceaccount.yaml
│   │   ├── servicemonitor.yaml        # Prometheus scrape (conditional)
│   │   └── grafana-dashboard.yaml     # Dashboard ConfigMap (conditional)
│   └── values/
│       ├── nonprod/
│       │   ├── ns1-dev.yaml
│       │   ├── ns2-staging.yaml
│       │   └── ns3-qa.yaml
│       └── prod/
│           └── ns1-prod.yaml
├── docs/
│   ├── architecture.md                # Detailed topology, storage, TLS, networking
│   ├── migration-guide.md             # Client changes, OpenWire quirks, cutover phases
│   ├── recovery.md                    # Tiered DR, EBS expansion, failover procedures
│   ├── load-testing-guide.md          # k6 scenarios, artemis perf, test phases
│   ├── amq-analysis-guide.md          # How to analyze current Classic deployment
│   ├── amq-classic-issues.md          # Known Classic problems driving migration
│   ├── artemis-storage-comparison.md  # Journal vs JDBC vs KahaDB analysis
│   └── next-steps.md                  # Detailed review findings and gap analysis
├── scripts/
│   └── amq-analyze.sh                 # Query Classic JDBC store for message stats
├── test/                              # Local test environment
│   ├── docker-compose.yml             # Classic (KahaDB + JDBC) + Artemis + apps + k6
│   ├── run-tests.sh                   # Automated compatibility test runner
│   ├── monolith-sim/                  # Java 8, OpenWire, Spring Boot 2.7
│   ├── microservice-sim/              # Java 21, native Artemis client, Spring Boot 3.4
│   ├── classic-jdbc/                  # Classic + PostgreSQL (mirrors prod)
│   ├── classic-kahadb/                # Classic + KahaDB (tuned file store)
│   ├── artemis-config/                # Test broker.xml
│   ├── k6/                            # Load test scripts
│   ├── TEST-SUMMARY.md                # Test results and findings
│   └── PERFORMANCE-TUNING.md          # JMS client + broker tuning guide
└── k6/scenarios/                      # EKS-targeted load test scenarios
```

## Helm Chart

Custom chart — no upstream dependency. Full control over broker.xml templating.

### Deploying

```bash
# Dev (single broker, no HA)
helm template artemis charts/artemis \
  -f charts/artemis/values/nonprod/ns1-dev.yaml

# Prod (cluster + replication HA)
helm template artemis charts/artemis \
  -f charts/artemis/values/prod/ns1-prod.yaml
```

### ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: artemis-ns1-prod
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/your-org/gitops-repo
    path: charts/artemis
    targetRevision: main
    helm:
      valueFiles:
        - values/prod/ns1-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: ns1
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Sync Wave Ordering

| Wave | Resources |
|---|---|
| -3 | StorageClass, ServiceAccount |
| -2 | Secret / ExternalSecret |
| -1 | Certificate, ConfigMaps |
| 0 | Services, NetworkPolicy, PDB |
| 1 | StatefulSets (live + backup) |
| 2 | Ingress, ServiceMonitor, Grafana Dashboard |

### Runtime Config Resolution

StatefulSet pods share the same PodSpec, but each broker needs a unique HA group name matching its ordinal (live-0/backup-0 = group-0, live-1/backup-1 = group-1). An init container resolves per-pod placeholders in broker.xml at startup:

```
  ┌─────────────────────────────────────────────────────────────┐
  │ ConfigMap (broker-live.xml)                                 │
  │   <name>__HOSTNAME__</name>                                 │
  │   <group-name>__HA_GROUP__</group-name>                     │
  │   <connector-ref>live-__ORDINAL__</connector-ref>           │
  └──────────────────────┬──────────────────────────────────────┘
                         │ mounted read-only at /config-template
                         ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ config-init container                                       │
  │   ORDINAL=${HOSTNAME##*-}    (e.g. artemis-live-1 -> 1)     │
  │   sed  __HA_GROUP__  -> group-1                             │
  │        __HOSTNAME__  -> artemis-live-1                      │
  │        __ORDINAL__   -> 1                                   │
  └──────────────────────┬──────────────────────────────────────┘
                         │ writes to emptyDir /config-resolved
                         ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ artemis container                                           │
  │   mounts /config-resolved/broker.xml                        │
  │   starts with default image entrypoint                      │
  └─────────────────────────────────────────────────────────────┘
```

### Secrets Management

Three strategies (mutually exclusive, set per environment):

| Strategy | Config | Use Case |
|---|---|---|
| Helm-generated | Default | Dev/test |
| External Secrets Operator | `broker.externalSecrets.enabled: true` | Prod (SSM or Vault) |
| Pre-existing Secret | `broker.auth.existingSecret: "name"` | BYO lifecycle |

### Key Ports

| Port | Purpose |
|---|---|
| 61616 | Client connections (OpenWire/CORE/AMQP) |
| 61617 | Cluster connections (live-to-live) |
| 61618 | Replication (live-to-backup) |
| 8161 | Admin console (ALB ingress) |
| 9404 | JMX exporter (Prometheus) |

## Test Environment

Docker Compose environment for local compatibility and performance testing.

```bash
cd test

# Run compatibility tests (32/33 pass)
./run-tests.sh

# Quick mode (skip large message tests)
./run-tests.sh --quick

# Include k6 load tests
./run-tests.sh --k6
```

### Test Results

| Path | Tests | Result |
|---|---|---|
| Monolith -> Classic KahaDB | 9 | All PASS |
| Monolith -> Classic JDBC | 9 | All PASS |
| Monolith -> Artemis (OpenWire) | 9 | 8 PASS, 1 FAIL |
| Microservice -> Artemis (native) | 6 | All PASS |

Known failure: OpenWire temp queue request/reply on Artemis. Only relevant if the monolith uses `createTemporaryQueue` / `setJMSReplyTo`.

### Performance

- Direct broker: **77,000 msg/sec** sustained (Artemis CORE protocol)
- Application-level (HTTP -> Spring -> JMS -> Broker): sub-7ms p95 at 50 msg/sec across all paths
- See `test/PERFORMANCE-TUNING.md` for detailed tuning guide

## Prerequisites

| Dependency | Status |
|---|---|
| EKS 1.34+ (amd64 node groups) | Confirmed |
| AWS Load Balancer Controller | Deployed |
| EBS CSI Driver | Deployed |
| Prometheus + Grafana | Deployed |
| Cluster Autoscaler | Deployed |
| ArgoCD | Deployed |
| cert-manager | May need install (prod TLS) |
| External Secrets Operator | TBD (SSM or Vault) |

## Open Questions

- Exact message size distribution (% PDFs, average PDF size)
- Consumer processing time per message
- Queue naming conventions
- Retention/expiry policies per queue
- JAAS auth: properties file or LDAP?
- Does the monolith use request/reply (temp queues)?
- What ACK mode does the monolith use?

## Documentation

| Doc | Purpose |
|---|---|
| [Architecture](docs/architecture.md) | Topology, storage, TLS, networking, observability |
| [Migration Guide](docs/migration-guide.md) | Client changes, OpenWire compatibility, cutover phases |
| [Recovery](docs/recovery.md) | Tiered DR, EBS expansion, failover procedures |
| [Load Testing Guide](docs/load-testing-guide.md) | k6 scenarios, test phases, validation criteria |
| [AMQ Analysis Guide](docs/amq-analysis-guide.md) | How to analyze current Classic deployment |
| [Classic Issues](docs/amq-classic-issues.md) | Known problems driving migration |
| [Storage Comparison](docs/artemis-storage-comparison.md) | Journal vs JDBC vs KahaDB |
| [Next Steps](docs/next-steps.md) | Detailed review findings and prioritized gap analysis |
