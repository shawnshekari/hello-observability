#!/usr/bin/env bash
# Tears down every workload from the Hello Observability PoC so nothing keeps
# running (or billing) while it's not in use: Camunda 8 (Zeebe) + its 32Gi
# PersistentVolumeClaim, n8n, the OTel Collector, the OTel Operator, and
# cert-manager.
#
# Deliberately left in place (both are free while idle, and removing them
# makes scripts/up.sh slow to re-run):
#   - The GKE Autopilot cluster itself (Autopilot has no cluster management
#     fee; with zero pods scheduled there's effectively nothing left to bill).
#   - The otel-collector-gsa service account and its IAM bindings.
# Pass --delete-cluster to also tear down the GKE cluster for true zero spend.
#
# Counterpart to scripts/up.sh. See README.md and ISSUE.md #1 for context.
set -euo pipefail

PROJECT_ID="hellootelworld"
REGION="us-central1"
CLUSTER_NAME="hello-observability-cluster"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DELETE_CLUSTER=false
[[ "${1:-}" == "--delete-cluster" ]] && DELETE_CLUSTER=true

echo "==> Using project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

if ! gcloud container clusters describe "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "==> Cluster ${CLUSTER_NAME} doesn't exist, nothing to tear down."
  exit 0
fi
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

echo "==> Uninstalling Camunda 8 (Zeebe)"
helm uninstall camunda-poc -n camunda 2>/dev/null || echo "    (release not found, skipping)"

echo "==> Deleting Zeebe PersistentVolumeClaims (this releases the billed persistent disk)"
kubectl delete pvc --all -n camunda --ignore-not-found

echo "==> Deleting camunda namespace"
kubectl delete namespace camunda --ignore-not-found --timeout=120s

echo "==> Deleting n8n"
kubectl delete -f "${REPO_ROOT}/k8s-infrastructure/n8n.yaml" --ignore-not-found

echo "==> Deleting the OTel Collector"
kubectl delete -f "${REPO_ROOT}/k8s-infrastructure/otel-collector.yaml" --ignore-not-found

echo "==> Uninstalling the OpenTelemetry Operator"
kubectl delete -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml --ignore-not-found

echo "==> Uninstalling cert-manager"
helm uninstall cert-manager -n cert-manager 2>/dev/null || echo "    (release not found, skipping)"
kubectl delete namespace cert-manager --ignore-not-found --timeout=120s

if [[ "${DELETE_CLUSTER}" == true ]]; then
  echo "==> --delete-cluster passed: deleting the GKE cluster ${CLUSTER_NAME}"
  gcloud container clusters delete "${CLUSTER_NAME}" --region "${REGION}" --quiet
fi

echo "==> Done. Remaining pods (should be none from this project's workloads):"
kubectl get pods -A --no-headers 2>/dev/null | grep -vE '^(kube-system|gke-|gmp-public)' || echo "  (none)"

echo "==> Remaining persistent disks (should be empty):"
gcloud compute disks list --format="table(name,sizeGb,status)"
