# Runbook: Kubernetes workload alerts

Rules: [`alerts/workloads.yaml`](../../alerts/workloads.yaml) · Tests: [`tests/workloads.test.yaml`](../../tests/workloads.test.yaml)

| Alert | Severity | Fires when |
| --- | --- | --- |
| [KubePodCrashLooping](#kubepodcrashlooping) | warning | a container in CrashLoopBackOff for 15m |
| [KubePodNotReady](#kubepodnotready) | warning | a pod Pending or not Ready for 15m (finished pods excluded) |
| [KubeHpaMaxedOut](#kubehpamaxedout) | warning | an HPA at `maxReplicas` for 15m |
| [KubePersistentVolumeFillingUp](#kubepersistentvolumefillingup) | warning | PVC < 15% free and predicted full within 4 days, for 1h |
| [KubePersistentVolumeFillingUp](#kubepersistentvolumefillingup) | critical | PVC < 3% free |

These alerts are about one workload, so the first question is always **what changed**:

```bash
kubectl -n "$NS" rollout history deploy/"$DEPLOY"
kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -30
helm -n "$NS" history "$RELEASE"          # or the Argo CD / Flux sync history
```

A workload alert becomes urgent when it also shows up as user impact: check the service's
SLO dashboard (Grafana, "SLO / Error budget") and [slo.md](slo.md).

## KubePodCrashLooping

**Symptoms.** A container keeps exiting and kubelet restarts it with an increasing back-off
(10s, 20s, 40s ... up to 5 minutes). The alert waits 15 minutes so a slow but successful
start, or a single crash, does not notify.

**Impact.** Depends on how many replicas are affected. One replica of a Deployment with
spare capacity: reduced headroom. All replicas, or a singleton: outage of that component.

**Triage.**

```bash
kubectl -n "$NS" get pod "$POD" -o wide
kubectl -n "$NS" describe pod "$POD"                  # Last State: reason, exit code, events
kubectl -n "$NS" logs "$POD" -c "$CONTAINER" --previous --tail=100
```

```promql
# All crash-looping containers, and how many replicas of the owner are affected
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}
# Restarts over the last hour for the namespace
sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="$NS"}[1h]))
# Was it OOM-killed?
kube_pod_container_status_last_terminated_reason{namespace="$NS", pod="$POD", reason="OOMKilled"}
```

Read the exit code: `137` = SIGKILL (OOMKilled or failed liveness probe), `1`/`2` = the
application exited with an error (config, missing secret, dependency down), `143` = SIGTERM.
In Kibana, query the `k8s-<namespace>-*` indices for the pod name to see logs from all
previous restarts, not just the last one.

**Mitigation.**

- Started after a deploy: roll back (`kubectl -n "$NS" rollout undo deploy/"$DEPLOY"`, or
  revert in Git for GitOps-managed apps) and debug afterwards.
- OOMKilled: raise the memory limit to what the container really needs, or fix the leak.
- Liveness probe kills a slow starter: add a `startupProbe` or increase `initialDelaySeconds`.
- Dependency down (database, secret, config): fix the dependency; the pod recovers by itself.

## KubePodNotReady

**Symptoms.** A pod has been `Pending`, or `Running` but failing its readiness probe, for
15 minutes. Pods that finished (`Succeeded`, e.g. Job pods) or were evicted (`Failed`) are
ignored.

**Impact.** The pod gets no Service traffic. Rolling updates stall when new pods never become
Ready, so a broken release is often visible here before anything else.

**Triage.**

```bash
kubectl -n "$NS" describe pod "$POD"   # Pending: look at Events (FailedScheduling, FailedMount, ErrImagePull)
kubectl -n "$NS" get pod "$POD" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'
```

```promql
# Pending because of insufficient capacity?
sum by (namespace) (kube_pod_status_phase{phase="Pending"})
sum(kube_pod_container_resource_requests{resource="cpu"}) / sum(kube_node_status_allocatable{resource="cpu"})
```

| Reason in events | Likely fix |
| --- | --- |
| `FailedScheduling: Insufficient cpu/memory` | Cluster autoscaler not scaling (limits, quota, instance availability) or requests too high |
| `FailedScheduling: node(s) had untolerated taint` / affinity | Wrong nodeSelector, affinity or toleration in the manifest |
| `FailedMount` / `FailedAttachVolume` | PVC in another zone than the node, volume still attached elsewhere, CSI driver problem |
| `ErrImagePull` / `ImagePullBackOff` | Wrong tag, registry auth, registry rate limit |
| Readiness probe failed | App not healthy (dependency, config) or probe too strict |

**Mitigation.** Fix the cause from the table. For a stuck rollout, `kubectl rollout undo`
restores the previous ReplicaSet while you investigate.

## KubeHpaMaxedOut

**Symptoms.** The HPA has been at `maxReplicas` for 15 minutes, so it cannot add capacity.

**Impact.** If load keeps rising, latency and errors follow. Check the service's SLO
burn rate: if it is fine, the max is simply sized for current peak and this is a capacity
planning signal, not an incident.

**Triage.**

```bash
kubectl -n "$NS" describe hpa "$HPA"   # current vs target metric, conditions (ScalingLimited)
kubectl -n "$NS" top pods -l "$SELECTOR"
```

```promql
kube_horizontalpodautoscaler_status_current_replicas{namespace="$NS", horizontalpodautoscaler="$HPA"}
kube_horizontalpodautoscaler_spec_max_replicas{namespace="$NS", horizontalpodautoscaler="$HPA"}
```

**Mitigation.**

- Real traffic growth: raise `maxReplicas` (check the cluster has room and downstream
  dependencies, e.g. database connections, can take more replicas).
- Unexpected traffic (bot, retry storm, a client in a loop): rate-limit or block at the edge
  instead of scaling into it.
- A regression made each request more expensive: roll back.

## KubePersistentVolumeFillingUp

**Symptoms.** Warning: the volume has less than 15% free and the 6-hour trend says it will
be full within 4 days. Critical: less than 3% free, regardless of trend.

**Impact.** When the volume is full, the application fails writes. Databases may crash or
switch to read-only; queues stop accepting messages.

**Triage.**

```bash
kubectl -n "$NS" get pvc "$PVC" -o wide
kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.storageClassName}'; echo
kubectl get storageclass "$SC" -o jsonpath='{.allowVolumeExpansion}'; echo
kubectl -n "$NS" exec "$POD" -- df -h "$MOUNT_PATH"
```

```promql
kubelet_volume_stats_available_bytes{namespace="$NS", persistentvolumeclaim="$PVC"}
  / kubelet_volume_stats_capacity_bytes{namespace="$NS", persistentvolumeclaim="$PVC"}
predict_linear(kubelet_volume_stats_available_bytes{namespace="$NS", persistentvolumeclaim="$PVC"}[6h], 24 * 3600)
```

**Mitigation.**

- Expand the volume if the StorageClass allows it:
  `kubectl -n "$NS" patch pvc "$PVC" -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'`.
  Most CSI drivers grow the filesystem online. For StatefulSets also update
  `volumeClaimTemplates` in Git, or the next re-creation goes back to the old size.
- Free space in the application: retention settings, compaction, old WAL or backups left
  on the volume.
- Growth is a bug (e.g. debug data, a runaway table): fix the writer first; expanding only
  buys time.

## Escalation

1. Warning alerts: the owning team handles them in working hours. The platform on-call
   steps in when the cause is the platform (scheduling, storage, image registry).
2. If the workload is user-facing and its SLO is burning, follow [slo.md](slo.md): that
   alert pages and sets the priority.
3. Data at risk (PVC critical on a database): page the owning team and the platform on-call
   together; do not delete data to free space without the owner.

## Post-incident

- Did the alert tell us before users did? If not, add or tune an SLO for the service.
- Missing guard rails found during triage (no limits, no startupProbe, no PodDisruptionBudget,
  StorageClass without expansion) become tickets with an owner.
- Write a postmortem for anything that paged or hit users: [postmortem template](../postmortem-template.md).
