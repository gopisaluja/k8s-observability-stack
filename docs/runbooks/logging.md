# Runbook: logging pipeline alerts

Rules: [`alerts/logging.yaml`](../../alerts/logging.yaml) · Dashboard: Grafana "Logging / Pipeline health"

| Alert | Severity | Fires when |
| --- | --- | --- |
| [FluentBitOutputErrors](#fluentbitoutputerrors) | warning | an output returns errors continuously for 15m |
| [FluentBitOutputRetriesFailed](#fluentbitoutputretriesfailed) | warning | chunks were dropped after exhausting retries (data loss) |
| [FluentBitPipelineStalled](#fluentbitpipelinestalled) | warning | a Fluent Bit pod reads records but delivers none for 15m |
| [ElasticsearchClusterRed](#elasticsearchclusterred) | critical | at least one primary shard unassigned for 5m |
| [ElasticsearchClusterYellow](#elasticsearchclusteryellow) | warning | replica shards unassigned for 30m |
| [ElasticsearchDiskSpaceLow](#elasticsearchdiskspacelow) | warning | a data node below 15% free disk for 15m |

Pipeline: Fluent Bit DaemonSet (namespace `logging`) → `logs-es-http:9200` (Elasticsearch
`logs`, managed by ECK) → Kibana `logs-kb-http`. Indices: `k8s-<namespace>-YYYY.MM.DD` and
`k8s-node-YYYY.MM.DD`, deleted after 7 days by the ILM policy `k8s-logs`.

Logging is not user-facing, which is why most of these are warnings. ElasticsearchClusterRed
pages because losing logs during an incident blinds everyone else's incident response.

## First checks for any logging alert

```bash
kubectl -n logging get elasticsearch,kibana
kubectl -n logging get pods -o wide
kubectl -n logging logs ds/fluent-bit --tail=50 | grep -iE 'error|warn|retry'

# Elasticsearch API through a port-forward (break-glass superuser)
kubectl -n logging port-forward svc/logs-es-http 9200 &
ES_PASS=$(kubectl -n logging get secret logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
curl -sk -u "elastic:${ES_PASS}" "https://localhost:9200/_cluster/health?pretty"
```

## FluentBitOutputErrors

**Symptoms.** An output (`es_kube` or `es_node`) has returned errors for 15 minutes. Records
are retried from the on-disk buffer.

**Impact.** Logs from the affected nodes arrive late. Nothing is lost yet, but the buffer
(`storage.total_limit_size`, 4G for container logs) is filling.

**Triage.**

```promql
sum by (pod, name) (rate(fluentbit_output_errors_total[5m]))
sum by (pod, name) (rate(fluentbit_output_retries_total[5m]))
# All pods or a few? A few points at node networking or DNS.
count(sum by (pod) (rate(fluentbit_output_errors_total[5m])) > 0)
```

```bash
kubectl -n logging logs "$POD" --tail=100 | grep -iE 'error|http_status|reason'
```

`Trace_Error On` makes Fluent Bit log the Elasticsearch response. Common ones:

| Error in the log | Meaning | Fix |
| --- | --- | --- |
| `status=429`, `es_rejected_execution_exception` | Write thread pool full | Usually self-heals; if sustained, scale Elasticsearch or reduce log volume |
| `status=401` / `403` | Credentials or role wrong | Check Secret `fluent-bit-es-credentials` and role `fluent_bit_writer` |
| `mapper_parsing_exception` | A field's type conflicts with the index mapping | Fix the log format, or let the next daily index pick the new type |
| `cluster_block_exception` ... `read-only` | Flood-stage disk watermark hit | See [ElasticsearchDiskSpaceLow](#elasticsearchdiskspacelow) |
| connection refused / TLS errors | Elasticsearch down or CA changed | Check the `logs` cluster and Secret `logs-es-http-certs-public` |

**Mitigation.** Fix the cause from the table. Mapping errors only drop the bad records;
everything else is retried and delivered once Elasticsearch accepts writes again.

## FluentBitOutputRetriesFailed

**Symptoms.** A chunk of records hit `Retry_Limit` (30 attempts, about 2.5 hours with the
5-minute back-off cap) and was discarded.

**Impact.** Those log records are lost. Check whether they matter (audit or security logs,
an incident under investigation).

**Triage.**

```promql
sum by (pod, name) (increase(fluentbit_output_retries_failed_total[1h]))
sum by (pod, name) (increase(fluentbit_output_dropped_records_total[1h]))
```

**Mitigation.** Find out why delivery failed for so long (usually an earlier
FluentBitOutputErrors or ElasticsearchClusterRed that was not handled). If loss is
unacceptable for some logs, ship them on a separate path with a larger buffer, or to
object storage as well.

## FluentBitPipelineStalled

**Symptoms.** A Fluent Bit pod has read records for 15 minutes but flushed none to any output.

**Impact.** Logs from that node are not reaching Elasticsearch and are piling up in its buffer.

**Triage.**

```promql
sum by (pod) (rate(fluentbit_input_records_total{pod="$POD"}[10m]))
sum by (pod) (rate(fluentbit_output_proc_records_total{pod="$POD"}[10m]))
sum by (pod, name) (fluentbit_input_storage_chunks{pod="$POD"})
```

```bash
kubectl -n logging describe pod "$POD"     # restarts, OOMKilled, memory limit
kubectl -n logging logs "$POD" --tail=200
```

**Mitigation.** If only one pod is stuck and nothing in its log explains it, delete the pod.
The DaemonSet recreates it and the filesystem buffer and tail offsets
(`/var/fluent-bit/state` on the node) are kept, so nothing is re-read or lost. If it was
OOMKilled, raise its memory limit or lower `storage.max_chunks_up`.

## ElasticsearchClusterRed

**Symptoms.** At least one primary shard is unassigned. Pages.

**Impact.** Writes to the affected indices fail (Fluent Bit retries and buffers), searches
return partial results. If the red index is today's index for a namespace, that namespace's
logs are not searchable.

**Triage.**

```bash
curl -sk -u "elastic:${ES_PASS}" "https://localhost:9200/_cluster/health?level=indices&pretty" | grep -B2 -A3 '"red"'
curl -sk -u "elastic:${ES_PASS}" "https://localhost:9200/_cat/shards?v&h=index,shard,prirep,state,unassigned.reason,node" | grep -v STARTED
curl -sk -u "elastic:${ES_PASS}" "https://localhost:9200/_cluster/allocation/explain?pretty"
kubectl -n logging get pods -l elasticsearch.k8s.elastic.co/cluster-name=logs -o wide
kubectl -n logging get pvc
```

**Mitigation.**

- Node down (pod not running, PVC not attached): get the pod back first; ECK and Elasticsearch
  reallocate shards when it returns. Check node and PVC alerts.
- Disk watermark: free space (delete the oldest `k8s-*` indices, or expand the PVCs), then
  `PUT _all/_settings {"index.blocks.read_only_allow_delete": null}` if indices were blocked.
- Primary lost with no replica (data gone): as a last resort, and only for log indices,
  delete the red index or use `_cluster/reroute` with `allocate_empty_primary`. Record it
  in the incident timeline; those logs are lost.

## ElasticsearchClusterYellow

**Symptoms.** Replica shards have been unassigned for 30 minutes. Data is still available.

**Impact.** One more node failure could turn the cluster red or lose data.

**Triage.** `_cluster/allocation/explain` (above) tells you why. Typical causes: a node is
down or restarting, disk above the low watermark (85%), or more replicas configured than
nodes available.

**Mitigation.** Restore the missing node, free disk space, or (single-node test clusters
only) set `index.number_of_replicas: 0` in the index template.

## ElasticsearchDiskSpaceLow

**Symptoms.** A data node has less than 15% disk free, so it is past the low watermark and
receives no new shards. At 10% free (high watermark) Elasticsearch moves shards away; at 5%
(flood stage) it makes indices on that node read-only and ingestion stops.

**Triage.**

```bash
curl -sk -u "elastic:${ES_PASS}" "https://localhost:9200/_cat/allocation?v"
curl -sk -u "elastic:${ES_PASS}" "https://localhost:9200/_cat/indices/k8s-*?v&s=store.size:desc&h=index,docs.count,store.size" | head -20
```

```promql
elasticsearch_filesystem_data_available_bytes / elasticsearch_filesystem_data_size_bytes
# Log volume read per node (one Fluent Bit pod per node)
topk(10, sum by (pod) (rate(fluentbit_input_bytes_total[1h])))
```

Per-namespace indices make "who is filling the disk" easy to answer: the `_cat/indices`
output above is already sorted by size.

**Mitigation.**

- Delete the oldest indices now (`DELETE k8s-<namespace>-2026.01.01`), or shorten the ILM
  `delete` phase in `helm-values/elasticsearch.yaml`.
- A namespace logging far more than usual: work with the owners to lower the log level, or
  exclude it temporarily with the pod annotation `fluentbit.io/exclude: "true"`.
- Long term: expand the PVCs (`volumeClaimTemplates` in the Elasticsearch values; ECK
  supports volume expansion when the StorageClass does) or add data nodes.

## Escalation

1. ElasticsearchClusterRed pages the platform on-call. Everything else is handled in
   working hours unless an incident is running and needs logs.
2. During another incident, a logging problem becomes high priority: say so in the incident
   channel and fall back to `kubectl logs` for the affected services meanwhile.
3. Possible loss of audit or security logs: inform the security team.

## Post-incident

- Was data lost? How much (from `fluentbit_output_retries_failed_total`), and which namespaces?
- Was the buffer big enough to ride out the outage? Adjust `storage.total_limit_size` and
  `Retry_Limit` in `helm-values/fluent-bit.yaml`.
- Postmortem for any red cluster or data loss: [postmortem template](../postmortem-template.md).
