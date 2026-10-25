# Runbook: SLO burn-rate alerts

Rules: [`alerts/slo-example-api.yaml`](../../alerts/slo-example-api.yaml) · Tests: [`tests/slo-example-api.test.yaml`](../../tests/slo-example-api.test.yaml) · Dashboard: Grafana "SLO / Error budget"

| Alert | Severity | Fires when |
| --- | --- | --- |
| [SLOAvailabilityFastBurn](#sloavailabilityfastburn) | critical | 5xx ratio > 14.4x budget over 1h and 5m, or > 6x over 6h and 30m |
| [SLOAvailabilitySlowBurn](#sloavailabilityslowburn) | warning | 5xx ratio > 3x budget over 1d and 2h, or > 1x over 3d and 6h |
| [SLOLatencyFastBurn](#slolatencyfastburn) | critical | share of requests slower than 300ms > 14.4x budget (1h/5m) or 6x (6h/30m) |
| [SLOLatencySlowBurn](#slolatencyslowburn) | warning | same, 3x (1d/2h) or 1x (3d/6h) |

Objectives for `example-api` (30-day window): **99.9%** of requests succeed (budget 0.1%),
**99%** of requests complete in under **300ms** (budget 1%).

## How to read these alerts

- **Burn rate** is the error ratio divided by the error budget. At 1x the budget lasts
  exactly 30 days; at 14.4x it is gone in about 2 days.
- A **fast burn** means real users are failing right now at a rate that matters. It pages.
- A **slow burn** means the service will miss its monthly objective if nothing changes. It
  is a ticket for working hours, not a page.
- The alert labels tell you which SLO (`slo`), which service (`service`) and which
  tier (`burn=fast|slow`). Fast inhibits slow for the same SLO in Alertmanager.
- These are symptom alerts. They tell you users are hurting, not why. The cause is usually
  visible in the workload, node or dependency alerts that fire at the same time.

## First five minutes (any SLO alert)

1. Acknowledge the page and open the "SLO / Error budget" dashboard for the service. Note
   the burn rate per window and when it started.
2. Check what changed around the start time: deploys, config or feature-flag changes,
   infrastructure work, traffic pattern.
3. Look at other firing alerts in the same namespace:

```promql
ALERTS{alertstate="firing", namespace="$NS"}
```

4. If a change lines up with the start, **roll it back first** and investigate after. Rollback
   is the fastest mitigation for most burn-rate pages.

## SLOAvailabilityFastBurn

**Symptoms.** At least 2% of the monthly error budget was spent in the last hour (or 5%
in the last 6 hours), and errors are still happening (the short window confirms it).

**Impact.** A meaningful share of requests return 5xx right now. At this rate the whole
30-day budget is gone in 2-5 days.

**Triage.**

```promql
# Error ratio right now and by status code
slo:sli_error:ratio_rate5m{service="example-api", slo="availability"}
sum by (code) (rate(http_requests_total{job="example-api", code=~"5.."}[5m]))
# Is it one pod / one node, or all of them?
sum by (pod) (rate(http_requests_total{job="example-api", code=~"5.."}[5m]))
  / sum by (pod) (rate(http_requests_total{job="example-api"}[5m]))
```

```bash
kubectl -n "$NS" get pods -l app.kubernetes.io/name=example-api -o wide
kubectl -n "$NS" rollout history deploy/example-api
kubectl -n "$NS" logs -l app.kubernetes.io/name=example-api --since=15m --tail=50 | grep -iE 'error|exception|timeout'
```

In Kibana, filter the `k8s-<namespace>-*` data view on the service and `app.level: error`
(JSON log fields are nested under `app.`) around the start time.

**Mitigation.**

- Bad release: `kubectl -n "$NS" rollout undo deploy/example-api` (or revert in Git).
- One bad pod or node: delete the pod / cordon the node; the rest of the fleet carries traffic.
- Dependency failing (database, downstream API): fail over, shed load, or enable the
  degraded mode / feature flag the service has for it.
- Overload: scale out (check [KubeHpaMaxedOut](workloads.md#kubehpamaxedout)) or rate-limit
  at the edge.

The alert resolves on its own once the short windows (5m and 30m) drop below the threshold,
about 5-30 minutes after the errors stop.

## SLOAvailabilitySlowBurn

**Symptoms.** At least 10% of the monthly budget was spent over the last 1-3 days. Errors
are low but persistent.

**Impact.** No acute outage. The service is on track to miss its 99.9% objective this month.

**Triage.** Same queries as above over longer ranges (set the dashboard to 7 days). Look
for a constant background error rate: one endpoint, one client, a periodic job, retries
from a flaky dependency.

**Mitigation.** Open a ticket for the owning team with the evidence. If the remaining budget
is low, apply the error-budget policy (below).

## SLOLatencyFastBurn

**Symptoms.** More than 14.4% of requests (1h and 5m) or more than 6% (6h and 30m) took
longer than 300ms. Budget: 1% of requests may be slower.

**Impact.** Users see slow responses; clients with short timeouts see errors.

**Triage.**

```promql
# Latency percentiles now
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job="example-api"}[5m])))
histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{job="example-api"}[5m])))
# Saturation of the pods serving it
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="$NS", container="example-api"}[5m]))
  / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="$NS", container="example-api"}[5m]))
```

Typical causes: CPU throttling (limit too low), a slow dependency (database query, external
API), GC pauses after a memory change, noisy neighbour on a node, cold caches after a deploy.

**Mitigation.** Roll back a suspect release; scale out if CPU-bound; raise the CPU limit if
throttled; fail over or shed load if a dependency is slow.

## SLOLatencySlowBurn

**Symptoms.** At least 10% of the latency budget spent over 1-3 days.

**Impact.** Gradual degradation, often from data growth (slower queries), a gradual traffic
increase, or a change that added work to each request.

**Mitigation.** Ticket for the owning team: profile the slowest endpoints, check query plans
and caching, compare p99 before and after recent releases.

## Error-budget policy

When the 30-day budget (`slo:error_budget_remaining:ratio30d`) is:

| Remaining | Policy |
| --- | --- |
| > 50% | Ship normally. |
| 25-50% | Changes to this service need a rollback plan; reliability tickets get priority. |
| 0-25% | Only fixes and reliability work ship until the budget recovers. |
| < 0 | Feature freeze for this service; postmortem required. |

The policy is what gives the numbers teeth; agree on it with the service owners before
turning the alerts on.

## Escalation

1. Fast burn: the service on-call is paged. If the cause is not clear within 15 minutes,
   declare an incident, open a channel and name an incident commander.
2. Pull in the platform on-call when node, cluster or logging alerts fire at the same time.
3. Pull in the owners of the failing dependency as soon as it is identified.
4. Keep stakeholders updated every 30 minutes while users are affected.

## Post-incident

- Every fast-burn page gets a postmortem: [postmortem template](../postmortem-template.md).
  Include the budget spent (from the dashboard) as the impact figure.
- Check the alert itself: did it fire early enough, and did it page for something users did
  not notice? Adjust the SLO, not just the threshold, if it is consistently wrong.
- To add an SLO for another service, copy `alerts/slo-example-api.yaml`, change the selectors
  and objectives, and add a test case to `tests/`.
