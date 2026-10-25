#!/usr/bin/env bash
# Install or upgrade the observability stack into the current kube context.
#
# Safe to re-run: Helm releases use "upgrade --install", manifests use "kubectl apply",
# and generated credentials are only created when the Secret does not exist yet.
#
# Usage:
#   CLUSTER_NAME=prod-eu1 scripts/install.sh [all|metrics|logging|rules|dashboards|template]
#
#   all         metrics + logging (default)
#   metrics     kube-prometheus-stack, PrometheusRules from alerts/, dashboards
#   logging     ECK operator, Elasticsearch, Kibana, Fluent Bit, Elasticsearch exporter
#   rules       only re-apply alerts/
#   dashboards  only re-apply dashboards/
#   template    render every release with "helm template" into .build/rendered/
#               (no cluster needed; used by CI to catch values errors)
#
# Environment:
#   CLUSTER_NAME           required for "all"/"metrics"; added as cluster="..." to every alert
#   SLACK_WEBHOOK_URL      } Alertmanager receivers. When all three are set the Secret is
#   PAGERDUTY_ROUTING_KEY  } created or updated from them. When unset, an existing Secret is
#   DEADMANSSWITCH_URL     } left alone, or one with placeholders is created.
set -euo pipefail

# --- Pinned chart versions. Bump deliberately: read the changelog, run CI, then roll out.
readonly KPS_VERSION="92.11.0"         # prometheus-community/kube-prometheus-stack
readonly ECK_OPERATOR_VERSION="3.5.0"  # elastic/eck-operator
readonly ECK_STACK_VERSION="0.20.0"    # elastic/eck-elasticsearch, elastic/eck-kibana (ES/Kibana 9.5.0)
readonly FLUENT_BIT_VERSION="0.58.3"   # fluent/fluent-bit (Fluent Bit 5.1.x)
readonly ES_EXPORTER_VERSION="7.4.0"   # prometheus-community/prometheus-elasticsearch-exporter

# Namespaces are fixed: service names in helm-values/ and alerts/ refer to them.
readonly MONITORING_NS="monitoring"
readonly LOGGING_NS="logging"
readonly ECK_NS="elastic-system"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

TMP_DIR="$(mktemp -d)"
readonly TMP_DIR
trap 'rm -rf "${TMP_DIR}"' EXIT

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Prints the comment block at the top of this file.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

require() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required but not in PATH"
  done
}

ensure_namespace() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

secret_exists() {
  kubectl -n "$1" get secret "$2" >/dev/null 2>&1
}

random_password() {
  openssl rand -hex 24
}

# apply_secret_from_dir NAMESPACE NAME TYPE DIR
# Each file in DIR becomes one key. Values go through files, never through the command
# line, so they do not show up in `ps` or shell history.
apply_secret_from_dir() {
  local ns=$1 name=$2 type=$3 dir=$4
  kubectl -n "${ns}" create secret generic "${name}" --type="${type}" \
    --from-file="${dir}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# write_key DIR KEY VALUE
write_key() {
  mkdir -p "$1"
  chmod 700 "$1"
  printf '%s' "$3" >"$1/$2"
}

add_repos() {
  log "Adding Helm repositories"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm repo add elastic https://helm.elastic.co --force-update >/dev/null
  helm repo add fluent https://fluent.github.io/helm-charts --force-update >/dev/null
  helm repo update prometheus-community elastic fluent >/dev/null
}

# helm_install RELEASE CHART VERSION NAMESPACE VALUES_FILE [extra helm args...]
helm_install() {
  local release=$1 chart=$2 version=$3 ns=$4 values=$5
  shift 5
  log "helm upgrade --install ${release} (${chart} ${version}) in ${ns}"
  helm upgrade --install "${release}" "${chart}" \
    --version "${version}" \
    --namespace "${ns}" --create-namespace \
    --values "${REPO_ROOT}/helm-values/${values}" \
    --wait --timeout 10m \
    "$@"
}

ensure_alertmanager_secret() {
  local dir="${TMP_DIR}/alertmanager-receivers"
  if [[ -n "${SLACK_WEBHOOK_URL:-}" && -n "${PAGERDUTY_ROUTING_KEY:-}" && -n "${DEADMANSSWITCH_URL:-}" ]]; then
    log "Applying ${MONITORING_NS}/alertmanager-receivers from environment"
    write_key "${dir}" slack-webhook-url "${SLACK_WEBHOOK_URL}"
    write_key "${dir}" pagerduty-routing-key "${PAGERDUTY_ROUTING_KEY}"
    write_key "${dir}" deadmansswitch-url "${DEADMANSSWITCH_URL}"
  elif secret_exists "${MONITORING_NS}" alertmanager-receivers; then
    log "Keeping existing ${MONITORING_NS}/alertmanager-receivers"
    return 0
  else
    warn "receiver settings not set; creating alertmanager-receivers with placeholders."
    warn "Notifications will fail until it is updated (re-run with the three variables set)."
    write_key "${dir}" slack-webhook-url "https://hooks.slack.com/services/REPLACE/ME"
    write_key "${dir}" pagerduty-routing-key "REPLACE_ME"
    write_key "${dir}" deadmansswitch-url "https://example.invalid/heartbeat"
  fi
  apply_secret_from_dir "${MONITORING_NS}" alertmanager-receivers Opaque "${dir}"
}

ensure_grafana_secret() {
  local dir="${TMP_DIR}/grafana-admin"
  if secret_exists "${MONITORING_NS}" grafana-admin; then
    return 0
  fi
  log "Generating ${MONITORING_NS}/grafana-admin"
  write_key "${dir}" admin-user admin
  write_key "${dir}" admin-password "$(random_password)"
  apply_secret_from_dir "${MONITORING_NS}" grafana-admin Opaque "${dir}"
}

# ensure_es_user SECRET USERNAME ROLES  (ECK file-realm user, see helm-values/elasticsearch.yaml)
ensure_es_user() {
  local name=$1 user=$2 roles=$3 dir="${TMP_DIR}/$1"
  if secret_exists "${LOGGING_NS}" "${name}"; then
    return 0
  fi
  log "Generating ${LOGGING_NS}/${name} (Elasticsearch user ${user})"
  write_key "${dir}" username "${user}"
  write_key "${dir}" password "$(random_password)"
  write_key "${dir}" roles "${roles}"
  apply_secret_from_dir "${LOGGING_NS}" "${name}" kubernetes.io/basic-auth "${dir}"
}

# helm_template RELEASE CHART VERSION NAMESPACE VALUES_FILE OUT_DIR
helm_template() {
  local release=$1 chart=$2 version=$3 ns=$4 values=$5 out=$6
  log "helm template ${release} (${chart} ${version})"
  helm template "${release}" "${chart}" \
    --version "${version}" \
    --namespace "${ns}" \
    --values "${REPO_ROOT}/helm-values/${values}" \
    --api-versions monitoring.coreos.com/v1 \
    >"${out}/${release}.yaml"
}

template_all() {
  local out="${REPO_ROOT}/.build/rendered"
  mkdir -p "${out}"
  helm_template kube-prometheus-stack prometheus-community/kube-prometheus-stack "${KPS_VERSION}" \
    "${MONITORING_NS}" kube-prometheus-stack.yaml "${out}"
  helm_template eck-operator elastic/eck-operator "${ECK_OPERATOR_VERSION}" "${ECK_NS}" eck-operator.yaml "${out}"
  helm_template elasticsearch elastic/eck-elasticsearch "${ECK_STACK_VERSION}" "${LOGGING_NS}" elasticsearch.yaml "${out}"
  helm_template kibana elastic/eck-kibana "${ECK_STACK_VERSION}" "${LOGGING_NS}" kibana.yaml "${out}"
  helm_template fluent-bit fluent/fluent-bit "${FLUENT_BIT_VERSION}" "${LOGGING_NS}" fluent-bit.yaml "${out}"
  helm_template elasticsearch-exporter prometheus-community/prometheus-elasticsearch-exporter \
    "${ES_EXPORTER_VERSION}" "${LOGGING_NS}" elasticsearch-exporter.yaml "${out}"
  log "Rendered manifests are in ${out}"
}

apply_rules() {
  log "Applying PrometheusRules from alerts/"
  kubectl apply -f "${REPO_ROOT}/alerts/"
}

# Each dashboard becomes a ConfigMap labelled for the Grafana sidecar. Server-side apply
# avoids the 256KiB last-applied-configuration annotation limit on large dashboards.
apply_dashboards() {
  log "Applying Grafana dashboards from dashboards/"
  local file base
  for file in "${REPO_ROOT}"/dashboards/*.json; do
    base="$(basename "${file}" .json)"
    kubectl -n "${MONITORING_NS}" create configmap "dashboard-${base}" \
      --from-file="${base}.json=${file}" --dry-run=client -o yaml |
      kubectl label --local -f - grafana_dashboard=1 -o yaml |
      kubectl annotate --local -f - grafana_folder=k8s-observability-stack -o yaml |
      kubectl apply --server-side --force-conflicts --field-manager=k8s-observability-stack -f -
  done
}

install_metrics() {
  [[ -n "${CLUSTER_NAME:-}" ]] || die "CLUSTER_NAME is required (it becomes the cluster label on every alert)"
  ensure_namespace "${MONITORING_NS}"
  ensure_alertmanager_secret
  ensure_grafana_secret
  helm_install kube-prometheus-stack prometheus-community/kube-prometheus-stack "${KPS_VERSION}" \
    "${MONITORING_NS}" kube-prometheus-stack.yaml \
    --set-string "prometheus.prometheusSpec.externalLabels.cluster=${CLUSTER_NAME}"
  apply_rules
  apply_dashboards
}

install_logging() {
  kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 ||
    die "ServiceMonitor CRD not found; run '$0 metrics' first"

  helm_install eck-operator elastic/eck-operator "${ECK_OPERATOR_VERSION}" "${ECK_NS}" eck-operator.yaml

  ensure_namespace "${LOGGING_NS}"
  ensure_es_user fluent-bit-es-credentials fluent-bit fluent_bit_writer
  ensure_es_user es-exporter-credentials es-exporter es_exporter

  # The post-install hook Job waits for the cluster and applies ILM + index template.
  helm_install elasticsearch elastic/eck-elasticsearch "${ECK_STACK_VERSION}" "${LOGGING_NS}" \
    elasticsearch.yaml --timeout 20m
  log "Waiting for Elasticsearch to report Ready"
  kubectl -n "${LOGGING_NS}" wait elasticsearch/logs --for=jsonpath='{.status.phase}'=Ready --timeout=15m

  helm_install kibana elastic/eck-kibana "${ECK_STACK_VERSION}" "${LOGGING_NS}" kibana.yaml
  helm_install fluent-bit fluent/fluent-bit "${FLUENT_BIT_VERSION}" "${LOGGING_NS}" fluent-bit.yaml
  helm_install elasticsearch-exporter prometheus-community/prometheus-elasticsearch-exporter \
    "${ES_EXPORTER_VERSION}" "${LOGGING_NS}" elasticsearch-exporter.yaml
}

print_access() {
  cat <<EOF

Done. Access (port-forward):
  Grafana       kubectl -n ${MONITORING_NS} port-forward svc/kube-prometheus-stack-grafana 3000:80
                password: kubectl -n ${MONITORING_NS} get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
  Prometheus    kubectl -n ${MONITORING_NS} port-forward svc/kube-prometheus-stack-prometheus 9090
  Alertmanager  kubectl -n ${MONITORING_NS} port-forward svc/kube-prometheus-stack-alertmanager 9093
  Kibana        kubectl -n ${LOGGING_NS} port-forward svc/logs-kb-http 5601   (https, user "elastic")
                password: kubectl -n ${LOGGING_NS} get secret logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d
EOF
}

main() {
  local target="${1:-all}"
  case "${target}" in
    -h | --help)
      usage
      return 0
      ;;
    all | metrics | logging | rules | dashboards) ;;
    template)
      require helm
      add_repos
      template_all
      return 0
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  require kubectl helm openssl
  log "Kube context: $(kubectl config current-context)"

  case "${target}" in
    all)
      add_repos
      install_metrics
      install_logging
      ;;
    metrics)
      add_repos
      install_metrics
      ;;
    logging)
      add_repos
      install_logging
      ;;
    rules) apply_rules ;;
    dashboards) apply_dashboards ;;
  esac
  print_access
}

main "$@"
