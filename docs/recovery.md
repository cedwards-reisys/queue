# Disaster Recovery and Failure Handling

## Recovery Posture

- **RPO (Recovery Point Objective)**: Zero — synchronous replication means backup has every committed message
- **RTO (Recovery Time Objective)**: Seconds for broker failover, producers auto-retry via JMS failover URL
- **Scope**: Single region (us-east-2), 2 AZs. Full region outage is accepted risk.
- **Backup strategy**: Live→backup sync replication is the backup. No external snapshots needed for normal operations.

## Producer Failover URL

All producers should use the JMS failover transport:

```
failover:(tcp://artemis-live.ns1.svc.cluster.local:61616)?maxReconnectAttempts=-1&reconnectDelay=1000&reconnectDelayExponent=2&maxReconnectDelay=30000
```

| Parameter | Value | Purpose |
|---|---|---|
| `maxReconnectAttempts` | -1 | Retry forever |
| `reconnectDelay` | 1000 | Start with 1s between attempts |
| `reconnectDelayExponent` | 2 | Exponential backoff |
| `maxReconnectDelay` | 30000 | Cap at 30s between attempts |

The K8s ClusterIP Service (`artemis-live`) routes to whichever live broker is up. The producer doesn't need to know which pod — it just reconnects to the Service.

## Consumer Reconnection

Same failover URL as producers. When a live broker fails:

1. Consumer's TCP connection drops
2. JMS failover transport retries against the Service
3. Service routes to surviving live broker (or newly promoted backup)
4. Consumer re-subscribes to its queue
5. Messages that were delivered but not ACK'd are redelivered

**Important**: Use `CLIENT_ACKNOWLEDGE` or `SESSION_TRANSACTED` mode. With `AUTO_ACKNOWLEDGE`, messages delivered but not yet processed are lost on failover.

---

## Tier 1 — Automatic Recovery (no human intervention)

These scenarios are handled entirely by Kubernetes + Artemis replication. Producers and consumers auto-reconnect.

### Pod Crash

| Item | Detail |
|---|---|
| **Trigger** | OOMKilled, application error, liveness probe failure |
| **What happens** | K8s restarts the pod. EBS volume is still attached to the node. Journal intact. |
| **RTO** | Seconds |
| **Data loss** | Zero — journal survives pod restart |
| **Action required** | None. Check logs after: `kubectl logs artemis-live-0 -n ns1 --previous` |

### Node Failure

| Item | Detail |
|---|---|
| **Trigger** | EC2 instance terminated, hardware failure, spot reclaim |
| **What happens** | Pod evicted. K8s reschedules to new node in same AZ. EBS volume detaches and reattaches to new node. |
| **RTO** | 1-2 minutes (EBS detach/attach + pod startup) |
| **Data loss** | Zero — EBS volume survives node loss |
| **Action required** | None. Monitor: `kubectl get pods -n ns1 -w` |
| **Note** | EBS is AZ-locked. Pod must reschedule to same AZ as its volume. Anti-affinity uses `preferred` for same-role spread so this isn't blocked. |

### Live Broker Failure

| Item | Detail |
|---|---|
| **Trigger** | Live broker becomes unresponsive, network partition from backup |
| **What happens** | Backup detects lost heartbeat on replication channel. Quorum vote (quorum-size=1). Backup self-promotes to live. Clients reconnect via Service. |
| **RTO** | ~10-30 seconds |
| **Data loss** | Zero — synchronous replication means backup has all committed messages |
| **Action required** | None for recovery. After: investigate why original live failed, restart it as new backup. |

### Single AZ Outage

| Item | Detail |
|---|---|
| **Trigger** | us-east-2a or us-east-2b goes down |
| **What happens** | One live and one backup are in each AZ. The cross-AZ backup for the affected live promotes. The other group's live (already in surviving AZ) is unaffected. |
| **RTO** | ~10-30 seconds |
| **Data loss** | Zero |
| **Action required** | None for recovery. Capacity reduced to 1 live broker until AZ recovers. |

**Example: us-east-2a goes down**

```
BEFORE                              AFTER
us-east-2a    us-east-2b            us-east-2a    us-east-2b
live-0     ←→ live-1                (DOWN)        live-1      ← still serving
backup-1      backup-0              (DOWN)        backup-0    ← PROMOTES to live
                                                  Now: 2 live in us-east-2b
```

---

## Tier 2 — Runbook Recovery (human intervention required)

### Bad Deployment (CrashLoopBackOff)

| Item | Detail |
|---|---|
| **Trigger** | Bad broker.xml, invalid config, broken image |
| **Symptoms** | All pods in CrashLoopBackOff. No brokers serving traffic. |
| **RTO** | ~5 minutes |
| **Data loss** | Zero — journals untouched, pods just can't start |

**Steps:**
```bash
# 1. Identify the bad revision
kubectl get pods -n ns1
kubectl logs artemis-live-0 -n ns1

# 2. Rollback via ArgoCD
argocd app rollback artemis-ns1 --prune

# OR rollback via Helm
helm rollback artemis -n ns1

# 3. Verify pods recover
kubectl get pods -n ns1 -w
```

### EBS Volume Corruption

| Item | Detail |
|---|---|
| **Trigger** | Filesystem corruption, EBS hardware failure (rare) |
| **Symptoms** | Broker logs show journal read errors, pod won't start |
| **RTO** | ~10-15 minutes |
| **Data loss** | Zero if backup has full copy. Messages on corrupted volume only if both live+backup are affected (extremely unlikely). |

**Steps:**
```bash
# 1. Identify affected pod
kubectl describe pod artemis-live-0 -n ns1

# 2. Check if the OTHER broker in this group (backup) is healthy
kubectl logs artemis-backup-0 -n ns1

# 3. If backup is healthy with full journal:
#    Delete the corrupted PVC. StatefulSet recreates it.
#    New live pod syncs journal from backup.
kubectl delete pvc data-artemis-live-0 -n ns1
kubectl delete pod artemis-live-0 -n ns1
# StatefulSet recreates PVC with fresh volume
# Artemis syncs journal from backup via replication

# 4. Monitor sync progress
kubectl logs artemis-live-0 -n ns1 | grep -i "synchronization\|sync\|replica"
```

### Accidental PVC Deletion

Same procedure as volume corruption. The backup holds a full copy of the journal.

**Prevention**: Set PV reclaim policy to `Retain`:
```yaml
# In StorageClass
reclaimPolicy: Retain
```

With `Retain`, deleting a PVC doesn't delete the underlying EBS volume. You can manually recover data from the orphaned PV.

### Failed Backup Promotion

| Item | Detail |
|---|---|
| **Trigger** | Backup fails to promote after live dies (quorum vote fails, network issue) |
| **Symptoms** | No live broker serving traffic, backup stuck in "BACKUP" state |

**Steps:**
```bash
# 1. Check backup status
kubectl logs artemis-backup-0 -n ns1 | grep -i "quorum\|vote\|promote\|active"

# 2. If quorum vote failed due to network:
#    Force promotion by restarting the backup pod
kubectl delete pod artemis-backup-0 -n ns1
# On restart, backup re-evaluates quorum and should promote if live is truly gone

# 3. If backup is corrupted or won't start:
#    The other live/backup group should still be serving traffic
#    Focus on restoring the healthy group first
kubectl get pods -n ns1 -l app=artemis
```

### Recovering a Failed Broker Group

After a failure, the original live may restart as a backup (it was behind). To restore normal topology:

```bash
# 1. Check which pods are live vs backup
kubectl exec artemis-live-0 -n ns1 -- /var/lib/artemis/bin/artemis data print | head

# 2. The Artemis HA policy with check-for-active-server handles this:
#    - Original live restarts
#    - Sees the promoted backup is now live
#    - Becomes the new backup
#    - Syncs journal from the new live
#    No manual intervention needed — just verify both pods are running
```

---

## Tier 3 — Catastrophic (accepted risk)

### Full Region Outage (us-east-2)

| Item | Detail |
|---|---|
| **Impact** | Total outage. All brokers, all consumers, all producers down. |
| **Data loss** | None — EBS volumes survive region recovery |
| **Recovery** | Wait for region to recover. Pods restart automatically. Journals intact. |
| **Mitigation** | None deployed. Multi-region would require cross-region replication (not worth the complexity for this workload). |

### KMS Key Deletion

| Item | Detail |
|---|---|
| **Impact** | All EBS volumes encrypted with that key become permanently unreadable |
| **Recovery** | **Cannot recover.** All journal data is lost. |
| **Mitigation** | AWS KMS key deletion has a mandatory 7-30 day waiting period. Set CloudTrail alerts on `ScheduleKeyDeletion` API calls. Cancel before the waiting period expires. |

```bash
# Cancel a scheduled key deletion
aws kms cancel-key-deletion --key-id $KEY_ID --region us-east-2
```

### Total Loss of All 4 EBS Volumes

| Item | Detail |
|---|---|
| **Impact** | All journal data lost. Queue definitions, unconsumed messages, DLQ messages — all gone. |
| **Recovery** | Redeploy via ArgoCD. Brokers start fresh. Queue definitions recreated automatically via `autoCreate`. Unconsumed messages are lost. |
| **Likelihood** | Extremely low — requires simultaneous failure of 4 independent EBS volumes across 2 AZs |

---

## What's on the EBS Volumes

Understanding what's on disk helps evaluate what you'd actually lose:

```
/var/lib/artemis/data/
├── journal/          # Message journal — ONLY contains unconsumed messages
│                     # Consumed messages are removed by compaction
│                     # If all queues are drained, journal is effectively empty
├── bindings/         # Queue and address definitions
│                     # Recreated automatically by autoCreate on first use
├── paging/           # Overflow when broker memory is full
│                     # Empty under normal load
└── large-messages/   # Messages > 100KB stored here instead of journal
                      # Removed when consumed, like journal entries
```

**Key insight**: A messaging system's disk is transient. Messages flow through — they're produced, persisted, consumed, and removed. At any given moment, the journal only contains:
- Messages not yet consumed (in-flight or queued)
- DLQ messages (persist until explicitly handled)
- Pre-allocated empty journal files

If your system is healthy and consumers are keeping up, the journals are nearly empty. The real DR value is in the **live→backup synchronous replication**, not in disk snapshots.

### When Disk-Level Backups Would Matter

EBS snapshots only add value if:
- Large backlog builds up (consumers down for extended period) AND both live+backup for that group are lost
- DLQ accumulates significant unprocessable messages you need to preserve
- You need point-in-time recovery for compliance/audit (messages are evidence)

For normal operations, the sync replication to backup IS the backup.

---

## Monitoring for Early Warning

Catch problems before they become outages:

| What to Monitor | Metric / Check | Alert Threshold |
|---|---|---|
| Replication sync | `artemis_broker_replica_sync` | Alert if `false` for >1 min |
| Broker connection count | `artemis_broker_ConnectionCount` | Alert if drops to 0 (clients disconnected) |
| Queue depth growing | `artemis_MessageCount` | Alert if any queue >10K for >5 min (consumers may be stuck) |
| Disk usage | `artemis_broker_disk_store_usage` | Alert at 70%, critical at 85% |
| DLQ depth | `artemis_MessageCount{queue=~"DLQ.*"}` | Alert if any DLQ >0 (messages failing) |
| Consumer count | `artemis_ConsumerCount` | Alert if drops to 0 on active queues |
| Pod restarts | `kube_pod_container_status_restarts_total` | Alert if >2 in 10 min |
| EBS IOPS saturation | CloudWatch `VolumeQueueLength` | Alert if >1 sustained |
| PVC capacity | `kubelet_volume_stats_used_bytes` | Alert at 80% |

### Quick Health Check

```bash
# All pods running?
kubectl get pods -n ns1 -l app=artemis

# Replication in sync?
kubectl exec artemis-live-0 -n ns1 -- \
  /var/lib/artemis/bin/artemis queue stat --url tcp://localhost:61616

# Any DLQ messages?
kubectl exec artemis-live-0 -n ns1 -- \
  /var/lib/artemis/bin/artemis queue stat --url tcp://localhost:61616 \
  --queueName 'DLQ.#'

# Disk usage
kubectl exec artemis-live-0 -n ns1 -- df -h /var/lib/artemis/data
```

---

## EBS Volume Expansion

Volumes can be expanded online without downtime using the EBS CSI driver. Volumes **cannot** be shrunk — EBS does not support size reduction.

### When to Expand

- Disk usage alert fires at 70%
- Anticipating a known batch processing event
- `amq-analyze.sh` data shows higher PDF volume than expected

### Procedure

**Step 1: Patch existing PVCs** (online, no pod restart)

```bash
# Set target size
NEW_SIZE="500Gi"
NAMESPACE="ns1"
RELEASE="artemis"

# Expand all 4 broker PVCs
for pod in live-0 live-1 backup-0 backup-1; do
  kubectl patch pvc data-${RELEASE}-${pod} -n ${NAMESPACE} \
    -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${NEW_SIZE}\"}}}}"
done

# Verify expansion (status should show FileSystemResizePending then complete)
kubectl get pvc -n ${NAMESPACE} -l app=artemis
```

The EBS CSI driver handles the resize automatically:
1. EBS volume is modified via AWS API (takes seconds)
2. Filesystem is expanded online (ext4 supports this)
3. Broker sees more disk space immediately — no restart needed

**Step 2: Update Helm values** (for future pods)

Update the storage size in the environment values file so new PVCs get the right size:

```yaml
# values/prod/ns1-prod.yaml
broker:
  storage:
    size: 500Gi   # was 200Gi
```

This is necessary because `volumeClaimTemplates` in a StatefulSet is immutable — Helm can't resize existing PVCs. The values update ensures any new pods (e.g. after a StatefulSet recreate) get the correct size.

**Step 3: Verify**

```bash
# Confirm PVC sizes
kubectl get pvc -n ${NAMESPACE} -l app=artemis -o custom-columns=\
NAME:.metadata.name,SIZE:.spec.resources.requests.storage,STATUS:.status.phase

# Confirm filesystem inside pod
kubectl exec ${RELEASE}-live-0 -n ${NAMESPACE} -- df -h /var/lib/artemis/data
```

### Important Notes

- **Growing**: Online, no downtime, takes seconds
- **Shrinking**: Not possible. EBS volumes cannot be reduced in size.
- **Changing StorageClass**: Not possible on existing PVCs. Requires delete + recreate.
- **Changing provisioned IOPS**: Must be done via AWS API or console, not through K8s:
  ```bash
  # Get volume ID from PV
  VOL_ID=$(kubectl get pv $(kubectl get pvc data-${RELEASE}-live-0 -n ${NAMESPACE} \
    -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}')

  # Modify IOPS
  aws ec2 modify-volume --volume-id ${VOL_ID} --iops 16000 --region us-east-2
  ```

---

## Summary

| Tier | Scenario | RTO | Data Loss | Action |
|---|---|---|---|---|
| **1 — Auto** | Pod crash | Seconds | Zero | None |
| **1 — Auto** | Node failure | 1-2 min | Zero | None |
| **1 — Auto** | Live broker dies | 10-30s | Zero | None |
| **1 — Auto** | AZ outage | 10-30s | Zero | None |
| **2 — Runbook** | Bad deployment | ~5 min | Zero | ArgoCD rollback |
| **2 — Runbook** | EBS corruption | ~10-15 min | Zero* | Delete PVC, resync from backup |
| **2 — Runbook** | Backup won't promote | ~5 min | Zero | Restart backup pod |
| **3 — Accepted** | Region outage | Hours | Zero | Wait for recovery |
| **3 — Accepted** | KMS key deleted | N/A | **Total** | Cancel within 7-30 day window |
| **3 — Accepted** | All 4 volumes lost | ~30 min | **Total** | Redeploy fresh, messages lost |

*Zero data loss assumes the backup for the affected group is healthy.
