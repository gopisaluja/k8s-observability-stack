# Runbook: control-plane alerts

Rules: [`alerts/control-plane.yaml`](../../alerts/control-plane.yaml)

| Alert | Severity | Fires when |
| --- | --- | --- |
| [KubeAPIServerDown](#kubeapiserverdown) | critical | no API server target scraped successfully for 15m |
| [KubeAPIServerLatencyHigh](#kubeapiserverlatencyhigh) | warning | p99 latency of non-LIST/WATCH requests > 1s for 10m |
| [KubeAPIServerErrorsHigh](#kubeapiservererrorshigh) | critical | > 5% of API requests return 5xx for 10m |
| [EtcdHighFsyncDurations](#etcdhighfsyncdurations) | warning | etcd WAL fsync p99 > 500ms for 10m (self-managed clusters only) |

On a managed control plane (EKS, GKE, AKS) you cannot fix the API server yourself. Your
job is to confirm whether the problem is on the provider's side or caused by a client in
the cluster, protect the workloads, and open a support case early with evidence.

## First checks for any control-plane alert

```bash
kubectl get --raw='/readyz?verbose' | tail -20
kubectl get --raw='/livez?verbose' | tail -5
time kubectl get nodes >/dev/null
kubectl get apiservices | grep -v True     # broken aggregated APIs (metrics-server, custom) slow discovery
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
```

Check the provider status page for the region. Running workloads keep serving traffic
while the API server is degraded; what breaks is anything that needs the API: deployments,
scaling (HPA, cluster autoscaler), new pods, controllers, leader elections.

## KubeAPIServerDown

**Symptoms.** Prometheus has not scraped any API server endpoint for 15 minutes.

**Impact.** Either the API is down (no deploys, no scaling, controllers stalled) or only
Prometheus lost access (blind spot, no user impact).

**Triage.** Tell the two cases apart first:

```bash
kubectl get --raw='/readyz'                                            # works from your laptop?
kubectl -n default get endpoints kubernetes                            # API server endpoints
kubectl -n monitoring logs sts/prometheus-kube-prometheus-stack-prometheus -c prometheus --tail=50 | grep -i apiserver
```

```promql
up{job="apiserver"}
# Prometheus' own view of the scrape error
scrape_samples_scraped{job="apiserver"}
```

**Mitigation.**

- API really down: managed cluster, open a P1 with the provider and freeze deploys.
  Self-managed: check the API server static pods / systemd units, certificates and etcd health.
- Only Prometheus affected: check its ServiceAccount token, RBAC (`kubectl auth can-i get
  /metrics --as=system:serviceaccount:monitoring:kube-prometheus-stack-prometheus`) and any
  NetworkPolicy or security group change between the nodes and the API endpoint.

## KubeAPIServerLatencyHigh

**Symptoms.** The 99th percentile latency of GET and mutating requests for a verb/resource is
above 1 second for 10 minutes. LIST and WATCH are excluded on purpose.

**Impact.** kubectl and deployments feel slow, controllers fall behind, admission-heavy
operations may time out.

**Triage.** Look for a noisy client or a slow webhook before blaming the API server:

```promql
# Which verbs and resources get the most requests
topk(10, sum by (verb, resource) (rate(apiserver_request_total{job="apiserver"}[5m])))
# Throttling: requests waiting in priority-and-fairness queues or rejected (429)
sum by (priority_level) (rate(apiserver_flowcontrol_rejected_requests_total[5m]))
# Admission webhooks are a common cause of slow writes
histogram_quantile(0.99, sum by (name, le) (rate(apiserver_admission_webhook_admission_duration_seconds_bucket[5m])))
# Self-managed only: is etcd slow?
histogram_quantile(0.99, sum by (le) (rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])))
```

**Mitigation.**

- A slow admission webhook (policy engine, service mesh injector): scale it, fix it, or as a
  last resort set its `failurePolicy: Ignore` / remove it, with the owner's agreement.
- A misbehaving controller or CronJob hammering the API (e.g. LISTs in a tight loop): scale
  it to zero and fix the client (use informers/watches, add back-off).
- Nothing in the cluster explains it: provider support case with the PromQL above as evidence.

## KubeAPIServerErrorsHigh

**Symptoms.** More than 5% of all API requests return 5xx for 10 minutes. Pages.

**Impact.** Controllers fail and retry, deployments fail, scaling may not happen. Workloads
already running are not directly affected.

**Triage.**

```promql
sum by (code, verb, resource) (rate(apiserver_request_total{job="apiserver", code=~"5.."}[5m]))
# 503s from an aggregated API (metrics.k8s.io, custom.metrics.k8s.io) are a classic
sum by (group, version) (rate(apiserver_request_total{job="apiserver", code="503"}[5m]))
```

```bash
kubectl get apiservices | grep -v True
kubectl -n kube-system get pods -l k8s-app=metrics-server
```

**Mitigation.**

- Errors concentrated on one aggregated API group: fix or remove that APIService (an
  unavailable `v1beta1.metrics.k8s.io` also breaks HPAs).
- Errors spread across all resources: control-plane problem. Managed: support case, freeze
  deploys. Self-managed: API server logs, etcd health, control-plane node resources.

## EtcdHighFsyncDurations

**Symptoms.** 99th percentile write-ahead-log fsync latency on an etcd member is above
500ms (healthy: single-digit milliseconds). Self-managed clusters only (kubeadm, RKE2);
`kubeEtcd` scraping is off in the Helm values for managed clusters, so it never fires there.

**Impact.** Slow fsyncs cause missed heartbeats, leader elections and API latency. Sustained,
the cluster becomes unstable.

**Triage.**

```promql
histogram_quantile(0.99, sum by (instance, le) (rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])))
histogram_quantile(0.99, sum by (instance, le) (rate(etcd_disk_backend_commit_duration_seconds_bucket[5m])))
increase(etcd_server_leader_changes_seen_total[1h])
etcd_mvcc_db_total_size_in_bytes
```

**Mitigation.** Move etcd to dedicated, low-latency disks (SSD/NVMe, provisioned IOPS) and
keep other I/O off them; defragment members one at a time if the DB has grown; check for a
noisy neighbour on the control-plane nodes.

## Escalation

1. `critical` alerts page the platform on-call. Declare an incident if deploys or scaling
   are affected for more than 15 minutes.
2. Managed control plane: open the provider support case within the first 30 minutes,
   with the PromQL screenshots, the time range and the cluster ID. Waiting rarely helps.
3. Self-managed: escalate to whoever owns the control-plane nodes; do not restart etcd
   members in parallel.

## Post-incident

- Was it a client in the cluster? Add a dashboard panel or alert for that client's request
  rate, and set API Priority and Fairness limits for it.
- Record provider case numbers and their RCA in the postmortem: [postmortem template](../postmortem-template.md).
