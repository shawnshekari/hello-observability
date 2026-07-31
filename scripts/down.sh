#!/usr/bin/env bash
# Tears down every workload from the Hello Observability PoC so nothing keeps
# running (or billing) while it's not in use.
#
# Order of teardown (reverse of up.sh):
#   Spring Boot -> Camunda 8 + PVCs -> n8n -> OTel Collector -> OTel Operator -> cert-manager
#
# Deliberately left in place (both are free while idle, and removing them
# makes scripts/up.sh slow to re-run):
#   - The GKE Autopilot cluster itself (Autopilot has no cluster management
#     fee; with zero pods scheduled there's effectively nothing left to bill).
#   - The otel-collector-gsa service account and its IAM bindings.
#
# Pass --delete-cluster to also tear down the GKE cluster for true zero spend.
#
# Counterpart to scripts/up.sh. See README.md and ISSUE.md #1 for context.
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
PROJECT_ID="hellootelworld"
REGION="us-central1"
CLUSTER_NAME="hello-observability-cluster"

# Namespace configuration
NS_OBSERVABILITY="observability"
NS_APPS="apps"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DELETE_CLUSTER=false
[[ "${1:-}" == "--delete-cluster" ]] && DELETE_CLUSTER=true

echo "==> Using project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

# Check if cluster exists
if ! gcloud container clusters describe "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "==> Cluster ${CLUSTER_NAME} doesn't exist, nothing to tear down."
  exit 0
fi

# Fetch kubeconfig
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

# ============================================================================
# Step 1: Uninstall Camunda 8 (Zeebe)
# ============================================================================
# Camunda 8 (including Elasticsearch, which now lives in this same Helm
# release - see ISSUE.md #2 addendum) is deployed via Helm. We uninstall it
# first because other services depend on it for workflow execution. The
# PVCs are deleted separately to release the billed persistent disk - this
# now covers both Zeebe's (32Gi) and Elasticsearch's (64Gi) volumes, since
# `--all` isn't scoped to a specific StatefulSet.
echo "==> Uninstalling Camunda 8 (Zeebe + Elasticsearch)"
helm uninstall camunda-poc -n ${NS_APPS} 2>/dev/null || echo "    (release not found, skipping)"

# Delete PersistentVolumeClaims to free up disk space (billed resource!)
echo "==> Deleting Zeebe/Elasticsearch PersistentVolumeClaims (releases the billed persistent disk)"
kubectl delete pvc --all -n ${NS_APPS} --ignore-not-found

# The Elasticsearch ComputeClass is a scheduling policy object, not itself a
# billed resource, so leaving it doesn't cost anything - but delete it
# anyway for symmetry with up.sh (which re-applies it idempotently on the
# next run regardless). The GKE node it caused to be provisioned gets
# reclaimed automatically by the cluster autoscaler once nothing schedules
# onto it anymore - no manual step needed for that part.
echo "==> Deleting the Elasticsearch ComputeClass"
kubectl delete -f "${REPO_ROOT}/k8s-infrastructure/elasticsearch-computeclass.yaml" --ignore-not-found

# ============================================================================
# Step 2: Delete n8n
# ============================================================================
# n8n is deployed via kubectl apply. We delete it using the same YAML
# file to ensure all resources (Deployment + Service) are removed.
echo "==> Deleting n8n"
kubectl delete -f "${REPO_ROOT}/k8s-infrastructure/n8n.yaml" --ignore-not-found

# ============================================================================
# Step 3: Delete Spring Boot App
# ============================================================================
# The Spring Boot app is deployed via kubectl apply. We delete it using
# the same YAML file to ensure all resources (Deployment + Service) are removed.
echo "==> Deleting Spring Boot App"
kubectl delete -f "${REPO_ROOT}/k8s-infrastructure/hello-observability-app.yaml" --ignore-not-found

# ============================================================================
# Step 4: Delete OTel Collector
# ============================================================================
# The OTel Collector is deployed via the OTel Operator CRD. We delete
# the CR to trigger the operator to clean up the collector deployment.
echo "==> Deleting the OTel Collector"
kubectl delete -f "${REPO_ROOT}/k8s-infrastructure/otel-collector.yaml" --ignore-not-found

# ============================================================================
# Step 5: Uninstall OTel Operator
# ============================================================================
# The OTel Operator is installed via a manifest. We delete it to remove
# the operator deployment and CRDs.
echo "==> Uninstalling the OpenTelemetry Operator"
kubectl delete -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml --ignore-not-found

# ============================================================================
# Step 6: Uninstall cert-manager
# ============================================================================
# cert-manager is installed via Helm. We uninstall it and delete the
# namespace to clean up all resources.
echo "==> Uninstalling cert-manager"
helm uninstall cert-manager -n cert-manager 2>/dev/null || echo "    (release not found, skipping)"
kubectl delete namespace cert-manager --ignore-not-found --timeout=120s

# ============================================================================
# Step 7: Delete namespaces
# ============================================================================
echo "==> Deleting namespaces"
kubectl delete namespace ${NS_APPS} --ignore-not-found --timeout=120s
kubectl delete namespace ${NS_OBSERVABILITY} --ignore-not-found --timeout=120s

# ============================================================================
# Step 8: Delete GKE cluster (optional)
# ============================================================================
# GKE Autopilot has no cluster management fee, so we keep it by default.
# Pass --delete-cluster to remove it for true zero spend.
if [[ "${DELETE_CLUSTER}" == true ]]; then
  echo "==> --delete-cluster passed: deleting the GKE cluster ${CLUSTER_NAME}"
  gcloud container clusters delete "${CLUSTER_NAME}" --region "${REGION}" --quiet
fi

# ============================================================================
# Summary
# ============================================================================
echo "==> Done. Remaining pods (should be none from this project's workloads):"
kubectl get pods -A --no-headers 2>/dev/null | grep -vE '^(kube-system|gke-|gmp-public)' || echo "  (none)"

echo "==> Remaining persistent disks (should be empty):"
gcloud compute disks list --format="table(name,sizeGb,status)"
