#!/usr/bin/env bash
# Brings the Hello Observability PoC back up on an existing (or fresh) GKE
# Autopilot cluster: cert-manager -> OTel Operator -> OTel Collector -> n8n
# -> Camunda 8 (Zeebe). Safe to re-run; every step is idempotent.
#
# Counterpart to scripts/down.sh. See README.md for the full manual walkthrough
# and ISSUE.md #1 for why the Workload Identity re-annotation step below exists.
set -euo pipefail

PROJECT_ID="hellootelworld"
REGION="us-central1"
CLUSTER_NAME="hello-observability-cluster"
COLLECTOR_KSA="cluster-collector-collector"
COLLECTOR_GSA="otel-collector-gsa@${PROJECT_ID}.iam.gserviceaccount.com"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Using project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

if ! gcloud container clusters describe "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "==> Cluster ${CLUSTER_NAME} not found, creating it (this takes several minutes)..."
  gcloud services enable container.googleapis.com cloudtrace.googleapis.com logging.googleapis.com monitoring.googleapis.com
  gcloud container clusters create-auto "${CLUSTER_NAME}" --region "${REGION}"
else
  echo "==> Cluster ${CLUSTER_NAME} already exists, reusing it"
fi

echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}"

echo "==> Installing/upgrading cert-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.4 \
  --set installCRDs=true \
  --set global.leaderElection.namespace=cert-manager \
  --wait --timeout 5m

echo "==> Installing/upgrading the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
kubectl rollout status deployment/opentelemetry-operator-controller-manager \
  -n opentelemetry-operator-system --timeout=120s

echo "==> Deploying the OTel Collector"
kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/otel-collector.yaml"
kubectl rollout status deployment/${COLLECTOR_KSA} -n default --timeout=120s

# The OTel Operator recreates the collector's ServiceAccount whenever the CR is
# (re)applied, which drops any manual annotation. The Workload Identity binding
# on the GSA side (roles/iam.workloadIdentityUser for
# hellootelworld.svc.id.goog[default/cluster-collector-collector]) is keyed by
# namespace+KSA-name and survives, so re-annotating here is all that's needed.
# See ISSUE.md #1.
echo "==> Re-binding collector ServiceAccount to ${COLLECTOR_GSA} (Workload Identity)"
kubectl annotate serviceaccount "${COLLECTOR_KSA}" -n default \
  iam.gke.io/gcp-service-account="${COLLECTOR_GSA}" --overwrite

echo "==> Restarting collector pod to pick up the identity binding"
kubectl delete pod -n default -l app.kubernetes.io/name=${COLLECTOR_KSA} --ignore-not-found
kubectl rollout status deployment/${COLLECTOR_KSA} -n default --timeout=120s

echo "==> Deploying n8n"
kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/n8n.yaml"

echo "==> Deploying Camunda 8 (Zeebe)"
helm repo add camunda https://helm.camunda.io >/dev/null
helm repo update >/dev/null
helm upgrade --install camunda-poc camunda/camunda-platform \
  --namespace camunda \
  --create-namespace \
  --version 11.12.3 \
  -f "${REPO_ROOT}/helm-values/camunda-values.yaml" \
  --wait --timeout 10m

echo "==> Done. Current pods:"
kubectl get pods -n default
kubectl get pods -n camunda

cat <<'EOF'

If Zeebe is stuck in CrashLoop from stale Raft state (e.g. after a partial
teardown), wipe it and reinstall:
  kubectl delete pvc --all -n camunda
  helm uninstall camunda-poc -n camunda
  ./scripts/up.sh

Verify metrics/traces are flowing with no PermissionDenied errors:
  kubectl logs -n default -l app.kubernetes.io/name=cluster-collector-collector --tail=50
EOF
