# Kafka + MirrorMaker 2 across AZs — Premium SSD scenario

> **TL;DR**: Two single-broker Kafka KRaft clusters, one pod in **AZ1** and one
> in **AZ2**, each backed by **Premium SSD (LRS)** via the AKS built-in disk
> CSI driver. MirrorMaker 2 runs in dedicated mode and replicates topics
> `az1 → az2` (active/passive). Disks are zone-pinned to the same AZ as their
> broker, exercising the LRS zone-locality + `WaitForFirstConsumer` binding
> path end-to-end.
>
> **Storage type**: `azure-disk` StorageClass (`disk.csi.azure.com`, `skuName:
> Premium_LRS`). AKS built-in CSI — *not* ACS-managed.
>
> **Validated**: 2026-05-26 against `aks-acsl-3dntcpfgfndgw` /
> `rg-acstor-lab` / AKS 1.34. All commands in this doc were executed and
> verified live before being written.

---

## 1. What this scenario teaches

- How a **zone-pinned LRS disk** behaves under a per-AZ pod schedule
  (`topology.kubernetes.io/zone` nodeSelector + `WaitForFirstConsumer` SC)
- That **app-level replication** (MirrorMaker 2) is the durability story for
  Kafka on LRS disks — the disk doesn't replicate across AZs, the workload does
- The MM2 default naming policy: source topic `demo.orders` on az1 becomes
  `az1.demo.orders` on az2 (loop-safe, used everywhere in active/active too)
- What MM2's three internal connectors do (Source / Checkpoint / Heartbeat)
  and where their state actually lives (Kafka internal topics, *not* MM2 disk)
- Why MM2 itself needs **no PVC** — it is stateless; only the source/target
  Kafka brokers need durable storage

---

## 2. Architecture

```
                      AKS cluster (rg-acstor-lab, australiaeast)

    storagepool node (AZ1)            storagepool node (AZ2)
    ┌────────────────────────┐        ┌────────────────────────┐
    │ kafka-az1-0 (KRaft)    │        │ kafka-az2-0 (KRaft)    │
    │ node.id=1              │        │ node.id=1              │
    │ cluster-id=…-az1-001   │        │ cluster-id=…-az2-002   │
    │   ▲                    │        │   ▲                    │
    │   │ /var/lib/kafka     │        │   │ /var/lib/kafka     │
    │   ▼                    │        │   ▼                    │
    │ PV (Premium_LRS, AZ1)  │        │ PV (Premium_LRS, AZ2)  │
    └────────────────────────┘        └────────────────────────┘
                ▲                                  ▲
                │ PLAINTEXT:9092                   │ PLAINTEXT:9092
                │                                  │
                │     ┌────────────────────────┐   │
                └─────│ MM2 (kafka-mm2 ns)     ├───┘
                      │ syspool, stateless     │
                      │ az1 → az2 replication  │
                      │ DefaultReplicationPol  │
                      └────────────────────────┘
```

Key design notes:
- **Two independent KRaft clusters** (separate `cluster-id`, separate quorum,
  separate disks). MM2 is the only thing that ties them together.
- **Single broker per side** keeps the lab cheap and isolates the storage
  story. Replication factor on internal/replicated topics is `1` everywhere
  — see `mm2.properties` in `20-mirrormaker2.yaml`. Production = ≥3.
- **`WaitForFirstConsumer`** on the `azure-disk` SC: the pod is scheduled to a
  zone first, then the disk is provisioned in that same zone. Without this
  the disk would land in a random AZ and `kubectl describe pod` would
  forever show `failed to attach volume`.
- **`fsGroup: 1000`** on the pod securityContext — the `apache/kafka:3.9.0`
  image runs as uid 1000 and won't be able to write to a freshly-formatted
  ext4 PV without this. (We learned this the hard way; the manifest has it
  baked in now.)

---

## 3. Prerequisites

1. AKS cluster from `infra/main.bicep` already deployed (`syspool` +
   `storagepool` across AZ1/2/3). If you're on a different cluster, make
   sure you have:
   - A node in `topology.kubernetes.io/zone=australiaeast-1`
   - A node in `topology.kubernetes.io/zone=australiaeast-2`
2. The `azure-disk` StorageClass applied (`disk.csi.azure.com`,
   `Premium_LRS`, `WaitForFirstConsumer`). If you haven't applied it from
   `manifests/storageclass/`, do that now.

Sanity check:

```bash
kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.azure.com/agentpool
kubectl get sc azure-disk
```

Expected: at least one node per `australiaeast-1` and `australiaeast-2`,
`azure-disk` StorageClass present with `WaitForFirstConsumer`.

---

## 4. Step-by-step lab

All commands below have been executed against the live `aks-acsl-3dntcpfgfndgw`
cluster (2026-05-26) and the outputs are real.

### 4.1 — Apply the storage class (if not already)

```bash
kubectl apply -f manifests/storageclass/azure-disk.yaml
```

### 4.2 — Create the three namespaces

```bash
kubectl apply -f manifests/workloads/kafka/00-namespaces.yaml
```

Expected:

```
namespace/kafka-az1 created
namespace/kafka-az2 created
namespace/kafka-mm2 created
```

### 4.3 — Deploy both Kafka brokers

```bash
kubectl apply -f manifests/workloads/kafka/10-kafka-az1.yaml
kubectl apply -f manifests/workloads/kafka/11-kafka-az2.yaml
```

Wait for them to come up (~60–90s including KRaft format + boot):

```bash
kubectl -n kafka-az1 rollout status statefulset/kafka-az1 --timeout=5m
kubectl -n kafka-az2 rollout status statefulset/kafka-az2 --timeout=5m
```

Verify both are `Running` and which node + zone they landed on:

```bash
kubectl -n kafka-az1 get pod -o wide
kubectl -n kafka-az2 get pod -o wide
```

Expected:

```
NAME          READY   STATUS    NODE                                  ...
kafka-az1-0   1/1     Running   aks-storagepool-...-vmss000000   (AZ1)
kafka-az2-0   1/1     Running   aks-storagepool-...-vmss000001   (AZ2)
```

### 4.4 — Confirm each PV is pinned to its expected AZ

This is the storage-side proof of the lab:

```bash
for pair in data-kafka-az1-0:kafka-az1 data-kafka-az2-0:kafka-az2; do
  pvc=${pair%%:*}; ns=${pair##*:}
  pv=$(kubectl -n $ns get pvc $pvc -o jsonpath='{.spec.volumeName}')
  echo "$ns/$pvc -> $pv"
  kubectl get pv $pv \
    -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0]}{"\n"}'
done
```

Expected (real output from the validated run):

```
kafka-az1/data-kafka-az1-0 -> pvc-69e86a4a-...
{"key":"topology.disk.csi.azure.com/zone","operator":"In","values":["australiaeast-1"]}
kafka-az2/data-kafka-az2-0 -> pvc-b0c4e7ec-...
{"key":"topology.disk.csi.azure.com/zone","operator":"In","values":["australiaeast-2"]}
```

The Premium SSD LRS disk literally lives in the same AZ as the broker pod.
This is what `WaitForFirstConsumer` buys you on a multi-AZ cluster.

### 4.5 — Create a source topic on az1

```bash
kubectl -n kafka-az1 exec kafka-az1-0 -- \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-az1-0.kafka-az1.kafka-az1.svc.cluster.local:9092 \
  --create --topic demo.orders --partitions 3 --replication-factor 1
```

Expected:

```
Created topic demo.orders.
```

(Ignore the `.` in topic-name warning — that's just Kafka metrics naming
advice. We're using `demo.orders` because MM2 is filtering on the `demo\..*`
regex.)

### 4.6 — Verify cross-namespace DNS/broker reachability

Before MM2 cares about it, prove that a client in `kafka-az1` can reach the
broker in `kafka-az2`:

```bash
kubectl -n kafka-az1 exec kafka-az1-0 -- \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-az2-0.kafka-az2.kafka-az2.svc.cluster.local:9092 \
  --list
```

Expected: empty list (no user topics on az2 yet) and no error.

### 4.7 — Deploy MirrorMaker 2

```bash
kubectl apply -f manifests/workloads/kafka/20-mirrormaker2.yaml
kubectl -n kafka-mm2 rollout status deployment/mm2 --timeout=2m
kubectl -n kafka-mm2 logs deployment/mm2 --tail=20
```

You'll see `Worker clientId=az2->az1, …` log lines even though we only
enabled `az1->az2` — that's normal. MM2 still loads the reverse-direction
worker for control-plane bookkeeping. The `RetriableException: Timeout
while loading consumer groups` you might see on first start is also normal
and self-resolves within ~30s once `__consumer_offsets` is bootstrapped.

### 4.8 — Produce some messages on az1

```bash
for i in 1 2 3 4 5; do
  echo "order-$i: msg from az1 at $(date -u +%H:%M:%S)"
done | kubectl -n kafka-az1 exec -i kafka-az1-0 -- \
  /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka-az1-0.kafka-az1.kafka-az1.svc.cluster.local:9092 \
  --topic demo.orders
```

### 4.9 — Confirm MM2 created the mirrored topic on az2

Give MM2 ~15–30s to refresh and replicate:

```bash
sleep 25
kubectl -n kafka-az2 exec kafka-az2-0 -- \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-az2-0.kafka-az2.kafka-az2.svc.cluster.local:9092 \
  --list
```

Expected (real output):

```
__consumer_offsets
az1.checkpoints.internal
az1.demo.orders          ← this is your replicated user topic
az1.heartbeats
heartbeats
mm2-configs.az1.internal
mm2-offsets.az1.internal
mm2-status.az1.internal
```

Anatomy of those topics:
- `az1.demo.orders` — your data, prefixed with the source-cluster alias by
  `DefaultReplicationPolicy`
- `az1.heartbeats` — MM2 heartbeat stream (1 msg every 5s by config); useful
  for measuring end-to-end lag
- `az1.checkpoints.internal` — committed consumer-group offsets translated
  from az1 → az2 (used by `kafka-consumer-groups.sh --describe` failover)
- `mm2-{configs,offsets,status}.az1.internal` — Kafka Connect's own state
  topics (MM2 is built on Connect under the hood)

### 4.10 — Consume the replicated messages on az2

```bash
kubectl -n kafka-az2 exec kafka-az2-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-az2-0.kafka-az2.kafka-az2.svc.cluster.local:9092 \
  --topic az1.demo.orders \
  --from-beginning --timeout-ms 10000
```

Expected (real output from the validated run):

```
order-1: msg from az1 at 06:32:46
order-2: msg from az1 at 06:32:46
order-3: msg from az1 at 06:32:46
order-4: msg from az1 at 06:32:46
order-5: msg from az1 at 06:32:46
```

The trailing `TimeoutException` after the 10s window is harmless — it just
means the consumer ran out of new messages before the timeout expired.

### 4.11 — (Optional) Watch live replication

In one terminal — produce continuously:

```bash
kubectl -n kafka-az1 exec -i kafka-az1-0 -- \
  /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka-az1-0.kafka-az1.kafka-az1.svc.cluster.local:9092 \
  --topic demo.orders
# type messages, press Enter, Ctrl-D to exit
```

In another — tail on the AZ2 side:

```bash
kubectl -n kafka-az2 exec kafka-az2-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-az2-0.kafka-az2.kafka-az2.svc.cluster.local:9092 \
  --topic az1.demo.orders
```

You should see each line appear on az2 with ~1–3 seconds of lag.

### 4.12 — (Optional) Inspect replication lag via heartbeats

```bash
kubectl -n kafka-az2 exec kafka-az2-0 -- \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-az2-0.kafka-az2.kafka-az2.svc.cluster.local:9092 \
  --topic az1.heartbeats --property print.timestamp=true --from-beginning \
  --timeout-ms 8000
```

Each record's print-timestamp minus the source heartbeat emit time
(`emit.heartbeats.interval.seconds=5`) is your end-to-end replication lag.

---

## 5. Failure scenarios to try

These all build directly on the manifests above — no extra YAML.

### 5.1 — Kill the az1 broker pod (pod-level kill, disk survives)

```bash
kubectl -n kafka-az1 delete pod kafka-az1-0
kubectl -n kafka-az1 get pod -w
```

The StatefulSet recreates the pod, reattaches the same Premium SSD LRS PV
(format step is skipped because `meta.properties` already exists), and MM2
reconnects. Producers/consumers experience ~30–60s of disruption.

### 5.2 — Lose the AZ1 storagepool node (zone outage simulation)

Cordon + drain the AZ1 storagepool node:

```bash
AZ1_NODE=$(kubectl get nodes -l topology.kubernetes.io/zone=australiaeast-1,kubernetes.azure.com/agentpool=storagepool -o jsonpath='{.items[0].metadata.name}')
kubectl cordon "$AZ1_NODE"
kubectl drain "$AZ1_NODE" --ignore-daemonsets --delete-emptydir-data --force
```

What you'll see:
- `kafka-az1-0` goes `Pending` — its **LRS disk lives in AZ1** and there's
  only one storagepool node per AZ in this lab. The scheduler can't find
  another AZ1 node to attach the disk to.
- **The disk does not move zones**. This is exactly the LRS limitation.
- MM2 stops replicating from az1 (Source connector errors), but the az2
  cluster + already-replicated data stay fully available.

Recovery: `kubectl uncordon "$AZ1_NODE"`. In a real zone outage the
mitigation is to provision multiple storagepool nodes per AZ *and/or* run
a multi-broker Kafka cluster with replicas spread across AZs (rack-awareness
via `broker.rack`). This single-broker-per-AZ + MM2 design intentionally
keeps zone failure as a manual-failover story.

### 5.3 — Failover read traffic from az1 to az2

If az1 is dead and consumers are on the az1 side, they need to:
1. Switch their bootstrap servers to `kafka-az2-0.kafka-az2.kafka-az2.svc.cluster.local:9092`
2. Subscribe to `az1.<original-topic>` instead of `<original-topic>`
3. Use MM2's `checkpoints` topic via `RemoteClusterUtils.translateOffsets()`
   (or `MirrorClient`) to translate their last-committed `__consumer_offsets`
   into the az2 namespace

Pattern: don't fail back automatically — once az1 returns, decide whether to
catch up (resume MM2) or promote az2 as the new primary and flip MM2's
direction.

---

## 6. Cleanup

```bash
# Drop just the Kafka scenario (keep the AKS cluster + storagepool)
kubectl delete -f manifests/workloads/kafka/20-mirrormaker2.yaml --ignore-not-found
kubectl delete -f manifests/workloads/kafka/11-kafka-az2.yaml --ignore-not-found
kubectl delete -f manifests/workloads/kafka/10-kafka-az1.yaml --ignore-not-found
kubectl -n kafka-az1 delete pvc data-kafka-az1-0 --ignore-not-found
kubectl -n kafka-az2 delete pvc data-kafka-az2-0 --ignore-not-found
kubectl delete -f manifests/workloads/kafka/00-namespaces.yaml --ignore-not-found
```

The PVCs are intentionally deleted last and explicitly — `kubectl delete -f`
on a StatefulSet manifest does **not** garbage-collect its
`volumeClaimTemplates`-spawned PVCs. The Premium SSD disks won't be released
back to Azure until those PVCs are gone.

For full lab teardown, see `docs/COST-CLEANUP.md`.

---

## 7. Cost shape (lab-grade, australiaeast list prices)

| Component | Spec | ~$/mo |
|---|---|---|
| 2 × Premium SSD LRS P4 (32 GiB) | included in pod | $9.92 |
| 2 × Kafka broker pods on existing storagepool | CPU/mem already paid | $0 incr. |
| MM2 deployment on existing syspool | tiny — 300m / 768Mi | $0 incr. |
| Cross-AZ traffic (MM2 → az2) | depends on produce rate | trivial at lab load |
| **Total marginal cost on top of the AKS cluster** | | **~$10/mo** |

So if you're already running the `aksstorage` AKS lab, this scenario adds
about $10/mo until you tear down the PVCs. That's the whole point of the
Premium SSD LRS path — cheap durable block storage when you're doing
**app-level replication** (Kafka, Cassandra, Postgres-with-Patroni) instead
of relying on the disk to replicate.

---

## 8. When to use this pattern vs the alternatives

| If you need… | Use this | Not this |
|---|---|---|
| Cross-AZ Kafka durability with app-level rep | **THIS** (LRS + MM2) | ZRS disks (overpaying — Kafka already replicates) |
| Cross-AZ failover for a single non-replicated DB | `premium-ssd-zrs` SC | LRS + MM2 (wrong tool — MM2 only works for Kafka) |
| Highest throughput / sub-ms latency for Kafka | Local NVMe on Lsv3 + ACS | LRS Premium SSD (still good, just slower than NVMe) |
| Lots of small Kafka clusters sharing storage | Elastic SAN | per-broker disks (disk-attach limits) |

→ Full picker matrix: `docs/SCENARIOS.md`
→ Concepts/why: `docs/STORAGE-ARCHITECTURE.md`

---

## 9. Reference

- [Kafka MirrorMaker 2 docs (kafka.apache.org)](https://kafka.apache.org/documentation/#georeplication)
- [KIP-382 — MirrorMaker 2.0 design](https://cwiki.apache.org/confluence/display/KAFKA/KIP-382%3A+MirrorMaker+2.0)
- [AKS Azure Disk CSI driver](https://learn.microsoft.com/azure/aks/azure-disk-csi)
- [Premium SSD v1 / v2 comparison](https://learn.microsoft.com/azure/virtual-machines/disks-types)
