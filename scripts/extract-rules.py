#!/usr/bin/env python3
"""Unwrap PrometheusRule manifests into plain Prometheus rule files.

The Prometheus Operator wants rules wrapped in a PrometheusRule custom resource
(apiVersion/kind/metadata/spec.groups). promtool only understands plain rule files
({"groups": [...]}). This script writes one plain rule file per manifest, with the same
basename, so promtool can check the rules and run the unit tests in tests/.

Usage:
    python3 scripts/extract-rules.py OUT_DIR alerts/*.yaml

Requires PyYAML.
"""
import os
import sys

import yaml


def extract(path):
    with open(path, encoding="utf-8") as fh:
        docs = [d for d in yaml.safe_load_all(fh) if d]
    groups = []
    for doc in docs:
        if doc.get("kind") != "PrometheusRule":
            raise ValueError(f"{path}: expected kind PrometheusRule, got {doc.get('kind')!r}")
        spec_groups = (doc.get("spec") or {}).get("groups")
        if not spec_groups:
            raise ValueError(f"{path}: PrometheusRule has no spec.groups")
        groups.extend(spec_groups)
    return groups


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_dir, paths = argv[1], argv[2:]
    os.makedirs(out_dir, exist_ok=True)
    for path in paths:
        try:
            groups = extract(path)
        except (OSError, ValueError, yaml.YAMLError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        out_path = os.path.join(out_dir, os.path.basename(path))
        with open(out_path, "w", encoding="utf-8") as fh:
            yaml.safe_dump({"groups": groups}, fh, sort_keys=False, width=1000)
        print(f"{path} -> {out_path} ({len(groups)} groups)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
