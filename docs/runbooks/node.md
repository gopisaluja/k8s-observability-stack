# Runbook: node alerts

Rules: [`alerts/node.yaml`](../../alerts/node.yaml)

| Alert | Severity | Fires when |
| --- | --- | --- |
| [NodeFilesystemSpaceFillingUp](#nodefilesystemspacefillingup) | warning | < 20% free and the 6h trend reaches 0 within 24h, for 1h |
| [NodeFilesystemAlmostOutOfSpace](#nodefilesystemalmostoutofspace) | critical | < 5% free for 15m |
| [NodeDiskPressure](#nodediskpressure) | warning | kubelet DiskPressure condition for 5m |
| [NodeMemoryHighUtilization](#nodememoryhighutilization) | warning | > 90% memory used for 15m |
| [NodeMemoryPressure](#nodememorypressure) | warning | kubelet MemoryPressure condition for 5m |
| [NodeNotReady](#nodenotready) | warning | node not Ready for 15m |

Node-exporter alerts carry `node` (node name, added by a relabeling in the Helm values) and
`instance` (`<node IP>:9100`). kube-state-metrics alerts carry `node`. cAdvisor metrics have no
`node` label, so the queries below join them with `kube_pod_info` to filter by node.

## First checks for any node alert

```bash
kubectl get nodes -o wide
kubectl describe node "$NODE"            # Conditions, Taints, Allocated resources, Events
kubectl get pods -A -o wide --field-selector spec.nodeName="$NODE"
kubectl get events -A --field-selector involvedObject.name="$NODE" --sort-by=.lastTimestamp | tail -20
```

Is it one node or many? One node is usually a workload or hardware problem. Many nodes at
once usually means a zone, network, image registry or control-plane problem: check
[control-plane.md](control-plane.md) and your cloud provider's status page before
touching individual nodes.

```promql
# How many nodes are affected right now
count(ALERTS{alertstate="firing", alertname=~"Node.*"}) by (alertname)
```

## NodeFilesystemSpaceFillingUp

**Symptoms.** A filesystem is below 20% free and has been shrinking fast enough over the
last 6 hours to hit zero within 24 hours.

**Impact.** None yet. If it keeps going, kubelet starts image garbage collection and then
evicts pods (DiskPressure), and anything writing to that filesystem fails.

**Triage.**

```promql
# Free space and trend for this mount
node_filesystem_avail_bytes{node="$NODE", mountpoint="$MOUNT"} / node_filesystem_size_bytes{node="$NODE", mountpoint="$MOUNT"}
deriv(node_filesystem_avail_bytes{node="$NODE", mountpoint="$MOUNT"}[1h])
# Which pods on the node use the most container filesystem (writable layer)
topk(10, sum by (namespace, pod) (container_fs_usage_bytes{container!=""})
  and on (namespace, pod) kube_pod_info{node="$NODE"})
```

```bash
# On the node (SSM / gcloud compute ssh / kubectl debug node/$NODE -it --image=busybox:1.36)
du -xh --max-depth=2 /var/lib/containerd /var/lib/kubelet /var/log 2>/dev/null | sort -h | tail -20
crictl images | wc -l
```

Common causes: a pod logging at debug level (container logs under `/var/log/pods`), an
`emptyDir` used as scratch space without `sizeLimit`, too many unused images, core dumps.

**Mitigation.**

- Noisy logger: lower the log level or roll back the release that raised it.
- `emptyDir` growth: set `resources.limits.ephemeral-storage` and `emptyDir.sizeLimit` so
  kubelet evicts that pod instead of hurting the whole node.
- Images: `crictl rmi --prune` on the node (kubelet GC normally does this at 85%).
- If the trend cannot be stopped: cordon and drain the node, then replace it or grow the disk
  through the node pool / launch template.

## NodeFilesystemAlmostOutOfSpace

**Symptoms.** A filesystem has less than 5% free for 15 minutes. Pages.

**Impact.** Writes are about to fail. On the root or containerd filesystem, kubelet is
already evicting pods and new pods cannot start on this node.

**Triage.** Same queries as [NodeFilesystemSpaceFillingUp](#nodefilesystemspacefillingup).
Confirm the mount point first: `/`, `/var/lib/containerd` and `/var/lib/kubelet` affect the
node; a data mount affects only the workload using it.

**Mitigation.**

1. Stop the bleeding: `kubectl cordon "$NODE"` so nothing new lands there.
2. Free space quickly: delete the offending pod (its `emptyDir` and writable layer go with
   it), prune images, remove core dumps.
3. If space cannot be recovered in minutes: `kubectl drain "$NODE" --ignore-daemonsets
   --delete-emptydir-data` and let the autoscaler or node group replace it.
4. Afterwards fix the cause (limits, log level, disk size) so it does not come back.

## NodeDiskPressure

**Symptoms.** Kubelet set `DiskPressure=True` (by default when the node filesystem or image
filesystem crosses its eviction threshold, typically below 10-15% free).

**Impact.** The node is tainted `node.kubernetes.io/disk-pressure:NoSchedule`; kubelet
garbage-collects images and evicts pods, starting with BestEffort ones.

**Triage.**

```bash
kubectl describe node "$NODE" | sed -n '/Conditions:/,/Addresses:/p'
kubectl get events -A --field-selector reason=Evicted --sort-by=.lastTimestamp | tail -20
```

```promql
min by (mountpoint) (node_filesystem_avail_bytes{node="$NODE"} / node_filesystem_size_bytes{node="$NODE"})
```

**Mitigation.** Same as [NodeFilesystemAlmostOutOfSpace](#nodefilesystemalmostoutofspace).
Clean up evicted pods afterwards: `kubectl get pods -A --field-selector status.phase=Failed`.

## NodeMemoryHighUtilization

**Symptoms.** Less than 10% of the node's memory has been available for 15 minutes.

**Impact.** None yet, but the next spike ends in OOM kills or kubelet MemoryPressure evictions.
Usually means pods use far more memory than they request, so the scheduler over-packed the node.

**Triage.**

```promql
# Biggest consumers on the node, compared with what they asked for
topk(10, sum by (namespace, pod) (container_memory_working_set_bytes{container!=""})
  and on (namespace, pod) kube_pod_info{node="$NODE"})
sum by (namespace, pod) (kube_pod_container_resource_requests{node="$NODE", resource="memory"})
# OOM kills on this node
increase(node_vmstat_oom_kill{node="$NODE"}[1h])
```

```bash
kubectl top pods -A --sort-by=memory | head -20
kubectl describe node "$NODE" | sed -n '/Allocated resources:/,/Events:/p'
```

**Mitigation.** Fix requests for the pods whose usage is far above their request (or set
memory limits equal to requests for critical workloads). Short term, cordon the node and
delete one of the large pods so it is rescheduled elsewhere. A memory leak is a release
problem: roll back.

## NodeMemoryPressure

**Symptoms.** Kubelet set `MemoryPressure=True`: available memory crossed the eviction
threshold (default `memory.available<100Mi`).

**Impact.** Kubelet is evicting pods (BestEffort first, then Burstable pods above their
requests). New pods are not scheduled on the node.

**Triage.** Same queries as [NodeMemoryHighUtilization](#nodememoryhighutilization), plus:

```bash
kubectl get events -A --field-selector reason=Evicted --sort-by=.lastTimestamp | tail -20
```

**Mitigation.** As for NodeMemoryHighUtilization. If system daemons are being squeezed,
check that the node pool reserves memory for the system (`kubeReserved` / `systemReserved`).

## NodeNotReady

**Symptoms.** The node's `Ready` condition has not been `True` for 15 minutes.

**Impact.** Pods on the node are not updated. After the `not-ready` toleration (default 5m)
they are evicted and rescheduled; StatefulSet pods are not, until the node is deleted or
comes back. Capacity is reduced.

**Triage.**

```bash
kubectl describe node "$NODE" | sed -n '/Conditions:/,/Addresses:/p'   # reason: kubelet stopped posting status?
kubectl get nodes -o wide | grep -v ' Ready'                            # one node or many?
# Cloud side: is the instance running, did it fail health checks, was it a spot reclaim?
```

```promql
# When did it stop reporting, and was it under pressure before?
kube_node_status_condition{node="$NODE", condition="Ready", status="true"}
node_load5{node="$NODE"}
```

**Mitigation.**

- Single node, instance unhealthy or unreachable: cordon, drain if possible, then delete
  the node object and let the node group replace the instance.
- Kubelet or container runtime crashed (reachable instance): restart the service on the node
  and collect `journalctl -u kubelet -u containerd` first (also in Kibana, index `k8s-node-*`).
- Many nodes: stop here and treat it as a platform incident (network, zone, control plane).

## Escalation

1. Critical alert, or more than one node affected: page the platform on-call (PagerDuty does
   this automatically for `severity=critical`). Open an incident channel.
2. Not mitigated in 30 minutes, or cloud provider issue suspected: escalate to the platform
   lead and open a support case with the provider (include instance IDs and timestamps).
3. Workload clearly at fault (log flood, memory leak): bring in the owning team; roll back
   their last change if they cannot be reached.

## Post-incident

- Was the alert early enough to act before impact? Tune the threshold or `for` if not.
- Did the affected pods have requests, limits and ephemeral-storage limits? File a ticket if not.
- Critical alerts get a postmortem: [postmortem template](../postmortem-template.md).
