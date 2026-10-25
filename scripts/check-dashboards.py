#!/usr/bin/env python3
"""Validate the Grafana dashboards in dashboards/*.json.

Checks that each file is valid JSON, has a title and a unique uid, defines a
"datasource" template variable, and that every panel and query uses that variable
(no hard-coded datasource UIDs, so the dashboards work in any Grafana).

Usage:
    python3 scripts/check-dashboards.py [dashboards/*.json]
"""
import glob
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASOURCE_REF = "${datasource}"


def iter_panels(panels):
    for panel in panels:
        yield panel
        yield from iter_panels(panel.get("panels", []))


def check(path, seen_uids):
    errors = []
    name = os.path.relpath(path, REPO_ROOT)
    try:
        with open(path, encoding="utf-8") as fh:
            dash = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{name}: invalid JSON: {exc}"]

    for key in ("uid", "title", "panels", "templating"):
        if not dash.get(key):
            errors.append(f"{name}: missing {key!r}")
    uid = dash.get("uid")
    if uid in seen_uids:
        errors.append(f"{name}: uid {uid!r} also used by {seen_uids[uid]}")
    seen_uids[uid] = name

    variables = (dash.get("templating") or {}).get("list", [])
    if not any(v.get("name") == "datasource" and v.get("type") == "datasource" for v in variables):
        errors.append(f"{name}: no 'datasource' template variable")

    ids = set()
    for panel in iter_panels(dash.get("panels", [])):
        title = panel.get("title", "?")
        if panel.get("id") in ids:
            errors.append(f"{name}: duplicate panel id {panel.get('id')} ({title})")
        ids.add(panel.get("id"))
        refs = [panel.get("datasource")] + [t.get("datasource") for t in panel.get("targets", [])]
        for ref in refs:
            if ref is not None and ref.get("uid") != DATASOURCE_REF:
                errors.append(f"{name}: panel '{title}' uses datasource {ref!r}, expected {DATASOURCE_REF}")
        for target in panel.get("targets", []):
            if not target.get("expr", "").strip():
                errors.append(f"{name}: panel '{title}' has a query without expr")
    return errors


def main(argv):
    paths = argv[1:] or sorted(glob.glob(os.path.join(REPO_ROOT, "dashboards", "*.json")))
    seen_uids, errors = {}, []
    for path in paths:
        errors.extend(check(path, seen_uids))
    for err in errors:
        print(f"error: {err}", file=sys.stderr)
    print(f"{len(paths)} dashboards checked, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
