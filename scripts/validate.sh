#!/usr/bin/env bash
# Run the CI checks locally: yamllint, dashboard and alert checks, promtool check/test
# and the shell linter. Rendering the Helm charts is separate: scripts/install.sh template.
#
# Needs python3 with PyYAML and yamllint, and docker (promtool and shellcheck run in
# containers, pinned to the same images as CI).
set -euo pipefail

PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-prom/prometheus:v3.15.0}"
SHELLCHECK_IMAGE="${SHELLCHECK_IMAGE:-koalaman/shellcheck:v0.11.0}"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

step() { printf '\n==> %s\n' "$*"; }

promtool() {
  docker run --rm --entrypoint promtool -v "${PWD}:/w:ro" -w /w "${PROMETHEUS_IMAGE}" "$@"
}

step "yamllint"
yamllint --strict .

step "Dashboards"
python3 scripts/check-dashboards.py

step "Alert hygiene (severity, annotations, runbook links)"
python3 scripts/lint-alerts.py

step "Unwrap PrometheusRule manifests for promtool"
rm -rf .build/rules
python3 scripts/extract-rules.py .build/rules alerts/*.yaml

step "promtool check rules"
promtool check rules .build/rules/*.yaml

step "promtool test rules"
promtool test rules tests/*.yaml

step "shellcheck"
docker run --rm -v "${PWD}:/mnt:ro" -w /mnt "${SHELLCHECK_IMAGE}" scripts/*.sh

step "All checks passed"
