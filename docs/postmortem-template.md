# Postmortem: <short description of what users experienced>

> Blameless by default. Describe what happened and why the system allowed it, not who to
> blame. People made reasonable decisions with the information they had at the time; the
> goal is to change the system so the next person has better information and safer tools.

| Field | Value |
| --- | --- |
| Incident ID | INC-YYYY-NNN |
| Date (UTC) | YYYY-MM-DD |
| Severity | SEV1 / SEV2 / SEV3 (see [definitions](#severity-definitions)) |
| Status | Draft / In review / Final |
| Authors | |
| Incident commander | |
| Services affected | |
| Detected by | Alert `<AlertName>` / customer report / engineer noticed / ... |
| Postmortem review date | |

## Summary

Three to five sentences a reader outside the team understands: what broke, who was affected
and for how long, what fixed it, and the one most important follow-up.

## Impact

- **User impact:** what users saw (errors, slowness, missing data), which users or regions,
  roughly how many requests or customers.
- **SLO impact:** error budget consumed, from the "SLO / Error budget" dashboard
  (e.g. "availability: 38% of the 30-day budget; 61% remaining").
- **Duration:** from first user impact to full recovery.
- **Data loss:** none / describe (including lost logs or metrics).
- **Revenue or contractual impact:** if known; otherwise "not assessed".

### Key timings

| Metric | Time | Duration from start |
| --- | --- | --- |
| Impact started | | 0 |
| Detected (alert fired / report received) | | TTD = |
| Acknowledged / responder engaged | | TTA = |
| Mitigated (users no longer affected) | | TTM = |
| Resolved (root cause fixed or safe state) | | TTR = |

## Timeline (UTC)

Facts only, with sources (alert, Slack message, deploy log, dashboard). Include the
decisions made and why, and the dead ends.

| Time | Event |
| --- | --- |
| hh:mm | Deploy of `service vX.Y.Z` starts (CI pipeline #...) |
| hh:mm | `SLOAvailabilityFastBurn` fires for `service`; on-call paged |
| hh:mm | On-call acknowledges, opens #inc-... |
| hh:mm | Rollback started |
| hh:mm | Error ratio back below threshold; alert resolves |

## Root cause analysis

### Trigger

The specific change or event that started the incident (a deploy, a config change, a
traffic spike, a dependency failure, an expired certificate).

### Root cause

Why the trigger caused user impact. Keep asking "why" until you reach something the team can
change (a missing test, a missing guard rail, an unsafe default, a gap in the design):

1. Why did users get errors? ...
2. Why did ...? ...
3. Why ...? ...
4. Why ...? ...
5. Why ...? ...

### Contributing factors

Things that did not cause the incident but made it worse or longer: a noisy alert that was
ignored, a runbook that was out of date, missing dashboards, a slow rollback path, a
single person holding the knowledge.

## Detection

- Which alert fired first, and how long after impact started?
- Did it go to the right person, with enough context (summary, description, runbook link)?
- Were there earlier signals (warnings, dashboards, logs) that could have caught it sooner?
- Were there alerts that fired but did not help (noise during the incident)?

## Response and recovery

- What did responders do, in order, and what actually fixed it?
- Was the runbook used? Was it correct? Link the runbook and list what to change.
- What slowed recovery (access, tooling, unclear ownership, waiting on a vendor)?

## What went well

-

## What went poorly

-

## Where we got lucky

Things that limited the impact by chance rather than by design. These are action items in
disguise.

-

## Action items

Each item has one owner and a ticket. Prefer items that remove a class of problems over
items that only fix this instance.

| # | Action | Type | Owner | Priority | Ticket | Due |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | | Prevent | | P1 | | |
| 2 | | Detect | | P2 | | |
| 3 | | Mitigate | | P2 | | |
| 4 | Update runbook `docs/runbooks/<group>.md` | Process | | P3 | | |

Types: **Prevent** (stop it happening again), **Detect** (find out sooner), **Mitigate**
(reduce impact or recover faster), **Process** (people, docs, communication).

## Supporting information

- Dashboards (with time range): Grafana links, Kibana saved searches.
- PromQL used during triage:

```promql
slo:sli_error:ratio_rate5m{service="<service>"}
```

- Relevant logs, deploy IDs, provider support case numbers.

## Severity definitions

| Severity | Definition | Postmortem |
| --- | --- | --- |
| SEV1 | Major user-facing outage or data loss; most users of a core service affected | Required, reviewed within 5 working days |
| SEV2 | Significant degradation or a subset of users affected; fast-burn SLO page | Required |
| SEV3 | Minor or internal impact (e.g. logging pipeline down, no user impact) | Optional; recommended if it may recur |
