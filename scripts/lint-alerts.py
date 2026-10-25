#!/usr/bin/env python3
"""Check alert hygiene for every alerting rule in alerts/*.yaml.

Each alert must have:
  - labels.severity: critical, warning or info
  - annotations: summary, description, runbook_url
  - a runbook_url pointing into docs/runbooks/ of this repo, at an anchor that exists
    as a heading in that runbook (GitHub-style anchor of the alert name)

Usage:
    python3 scripts/lint-alerts.py [alerts/*.yaml]

Requires PyYAML.
"""
import glob
import os
import re
import sys

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNBOOK_PREFIX = "https://github.com/gopisaluja/k8s-observability-stack/blob/main/"
SEVERITIES = {"critical", "warning", "info"}
REQUIRED_ANNOTATIONS = ("summary", "description", "runbook_url")


def github_anchor(heading):
    """Approximate GitHub's heading anchor: lowercase, drop punctuation, spaces to dashes."""
    text = heading.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors_in(markdown_path):
    anchors = set()
    with open(markdown_path, encoding="utf-8") as fh:
        for line in fh:
            match = re.match(r"^#{1,6}\s+(.*)$", line)
            if match:
                anchors.add(github_anchor(match.group(1)))
    return anchors


def check_alert(path, rule, anchor_cache):
    name = rule["alert"]
    where = f"{os.path.relpath(path, REPO_ROOT)}: {name}"
    errors = []

    severity = (rule.get("labels") or {}).get("severity")
    if severity not in SEVERITIES:
        errors.append(f"{where}: severity must be one of {sorted(SEVERITIES)}, got {severity!r}")

    annotations = rule.get("annotations") or {}
    for key in REQUIRED_ANNOTATIONS:
        if not str(annotations.get(key, "")).strip():
            errors.append(f"{where}: missing annotation {key!r}")

    url = annotations.get("runbook_url", "")
    if url:
        if not url.startswith(RUNBOOK_PREFIX + "docs/runbooks/"):
            errors.append(f"{where}: runbook_url must start with {RUNBOOK_PREFIX}docs/runbooks/")
        else:
            rel, _, anchor = url[len(RUNBOOK_PREFIX):].partition("#")
            target = os.path.join(REPO_ROOT, rel)
            if not os.path.isfile(target):
                errors.append(f"{where}: runbook {rel} does not exist")
            elif anchor != name.lower():
                errors.append(f"{where}: runbook anchor should be #{name.lower()}, got #{anchor}")
            else:
                if target not in anchor_cache:
                    anchor_cache[target] = anchors_in(target)
                if anchor not in anchor_cache[target]:
                    errors.append(f"{where}: no heading '{name}' in {rel}")
    return errors


def main(argv):
    paths = argv[1:] or sorted(glob.glob(os.path.join(REPO_ROOT, "alerts", "*.yaml")))
    errors, alerts, anchor_cache = [], 0, {}
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            for doc in yaml.safe_load_all(fh):
                if not doc:
                    continue
                for group in doc.get("spec", {}).get("groups", []):
                    for rule in group.get("rules", []):
                        if "alert" in rule:
                            alerts += 1
                            errors.extend(check_alert(path, rule, anchor_cache))
    for err in errors:
        print(f"error: {err}", file=sys.stderr)
    print(f"{alerts} alerts checked, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
