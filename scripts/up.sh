#!/usr/bin/env bash
# Brings the Hello Observability PoC back up on an existing (or fresh) GKE
# Autopilot cluster. This script deploys the full stack:
#
#   cert-manager -> OTel Operator -> OTel Collector -> n8n -> Camunda 8 -> Spring Boot App
#
# Each step is documented below to explain what's happening and why.
# Safe to re-run; every step is idempotent.
#
# Counterpart to scripts/down.sh. See README.md for the full manual walkthrough
# and ISSUE.md #1 for why the Workload Identity re-annotation step below exists.
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
PROJECT_ID="hellootelworld"
REGION="us-central1"
CLUSTER_NAME="hello-observability-cluster"
COLLECTOR_KSA="cluster-collector-collector"
COLLECTOR_GSA="otel-collector-gsa@${PROJECT_ID}.iam.gserviceaccount.com"

# Image configuration for Spring Boot app
DOCKER_IMAGE="gcr.io/${PROJECT_ID}/hello-observability-app"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Using project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

# ============================================================================
# Step 1: Create or verify GKE Autopilot cluster
# ============================================================================
# GKE Autopilot manages node pools for us. We just specify the region and
# let GKE handle the infrastructure. This is the simplest way to run K8s.
if ! gcloud container clusters describe "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "==> Cluster ${CLUSTER_NAME} not found, creating it (this takes several minutes)..."

  # Enable required GCP APIs:
  # - container.googleapis.com: GKE cluster management
  # - cloudtrace.googleapis.com: Distributed tracing (OTel traces)
  # - logging.googleapis.com: Cloud Logging (for logs)
  # - monitoring.googleapis.com: Cloud Monitoring (for metrics)
  gcloud services enable container.googleapis.com cloudtrace.googleapis.com logging.googleapis.com monitoring.googleapis.com

  # Create Autopilot cluster (no node management required)
  gcloud container clusters create-auto "${CLUSTER_NAME}" --region "${REGION}"
else
  echo "==> Cluster ${CLUSTER_NAME} already exists, reusing it"
fi

# Fetch kubeconfig so kubectl can talk to our cluster
echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}"

# ============================================================================
# Step 2: Install cert-manager (required by OTel Operator)
# ============================================================================
# cert-manager manages TLS certificates in K8s. The OTel Operator depends on
# it for webhook certificate management. We use Helm for easy installation.
#
# GKE Autopilot blocks namespace leadership in kube-system, so we override
# the leader election namespace to cert-manager.
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

# ============================================================================
# Step 3: Install OpenTelemetry Operator
# ============================================================================
# The OTel Operator provides a Kubernetes CRD (Custom Resource Definition)
# for managing OTel Collectors declaratively. Instead of applying raw
# collector YAML, we use the operator to manage the collector lifecycle.
echo "==> Installing/upgrading the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
kubectl rollout status deployment/opentelemetry-operator-controller-manager \
  -n opentelemetry-operator-system --timeout=120s

# ============================================================================
# Step 4: Deploy OTel Collector
# ============================================================================
# The OTel Collector is the central hub for telemetry data. It:
# - Receives OTLP traces from n8n and Spring Boot
# - Scrapes Prometheus metrics from Zeebe and Spring Boot
# - Exports everything to Google Cloud (Trace + Monitoring)
#
# The collector runs in the 'default' namespace and uses Workload Identity
# to authenticate with GCP APIs.
echo "==> Deploying the OTel Collector"
kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/otel-collector.yaml"
kubectl rollout status deployment/${COLLECTOR_KSA} -n default --timeout=120s

# ============================================================================
# Step 5: Bind OTel Collector to GCP Service Account (Workload Identity)
# ============================================================================
# GKE Autopilot requires Workload Identity for pods to access GCP APIs.
# The OTel Operator recreates the collector's ServiceAccount on every
# reconcile, so we must re-annotate it here to maintain the binding.
#
# This allows the collector pod to impersonate the GSA and export
# traces/metrics to GCP without API keys.
echo "==> Re-binding collector ServiceAccount to ${COLLECTOR_GSA} (Workload Identity)"
kubectl annotate serviceaccount "${COLLECTOR_KSA}" -n default \
  iam.gke.io/gcp-service-account="${COLLECTOR_GSA}" --overwrite

# Restart collector pod to pick up the new identity binding
echo "==> Restarting collector pod to pick up the identity binding"
kubectl delete pod -n default -l app.kubernetes.io/name=${COLLECTOR_KSA} --ignore-not-found
kubectl rollout status deployment/${COLLECTOR_KSA} -n default --timeout=120s

# ============================================================================
# Step 6: Deploy n8n (workflow automation)
# ============================================================================
# n8n is a workflow automation tool. We use it to:
# - Receive order validation requests from Camunda
# - Validate order data (quantity, format, etc.)
# - Return validation results to Camunda
#
# n8n is configured with OpenTelemetry enabled, so it exports traces
# to our OTel Collector automatically.
echo "==> Deploying n8n"
kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/n8n.yaml"

# Wait for n8n to be ready before importing workflow
echo "==> Waiting for n8n to be ready..."
kubectl rollout status deployment/n8n -n default --timeout=120s

# ============================================================================
# Step 7: Deploy Camunda 8 (Zeebe workflow engine)
# ============================================================================
# Camunda 8 (Zeebe) is our workflow orchestration engine. It:
# - Executes BPMN workflows
# - Calls n8n for order validation
# - Exports metrics to OTel Collector (scraped via Prometheus)
#
# We use Helm chart 11.12.3 (Camunda 8.6.x) to avoid kernel issues on
# Autopilot. Only Zeebe + Gateway are deployed (no UI, no Elasticsearch).
echo "==> Deploying Camunda 8 (Zeebe)"
helm repo add camunda https://helm.camunda.io >/dev/null
helm repo update >/dev/null
helm upgrade --install camunda-poc camunda/camunda-platform \
  --namespace camunda \
  --create-namespace \
  --version 11.12.3 \
  -f "${REPO_ROOT}/helm-values/camunda-values.yaml" \
  --wait --timeout 10m

# Wait for Zeebe to be ready
echo "==> Waiting for Zeebe to be ready..."
kubectl rollout status statefulset/camunda-poc-zeebe -n camunda --timeout=120s
kubectl rollout status deployment/camunda-poc-zeebe-gateway -n camunda --timeout=120s

# ============================================================================
# Step 8: Deploy Spring Boot App
# ============================================================================
# The Spring Boot app is our order service. It:
# - Exposes REST API for creating orders
# - Calls Camunda to start workflow instances
# - Exports custom business metrics via Micrometer/OTel
# - Uses OpenTelemetry Java agent for automatic instrumentation
echo "==> Deploying Spring Boot App"
kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/hello-observability-app.yaml"

# Wait for Spring Boot app to be ready
echo "==> Waiting for Spring Boot app to be ready..."
kubectl rollout status deployment/hello-observability-app -n default --timeout=120s

# ============================================================================
# Summary
# ============================================================================
echo "==> Done. Current pods:"
kubectl get pods -n default
kubectl get pods -n camunda

cat <<'EOF'

==> Deployment complete! Verify everything is working:

1. Check OTel Collector logs for successful exports:
   kubectl logs -n default -l app.kubernetes.io/name=cluster-collector-collector --tail=50

2. Test n8n webhook (port-forward first):
   kubectl port-forward svc/n8n-service 5678:5678
   curl -X POST http://localhost:5678/webhook/order-validation \
     -H "Content-Type: application/json" \
     -d '{"orderId": "test-1", "itemName": "Widget", "quantity": 2}'

3. Test Spring Boot app (port-forward first):
   kubectl port-forward svc/hello-observability-app 8080:80
   curl -X POST http://localhost:8080/orders \
     -H "Content-Type: application/json" \
     -d '{"orderId": "test-1", "itemName": "Widget", "quantity": 2}'

4. View traces in Google Cloud Console:
   https://console.cloud.google.com/traces?project=hellootelworld

5. View metrics in Google Cloud Console:
   https://console.cloud.google.com/monitoring?project=hellootelworld

If Zeebe is stuck in CrashLoop from stale Raft state (e.g. after a partial
teardown), wipe it and reinstall:
   kubectl delete pvc --all -n camunda
   helm uninstall camunda-poc -n camunda
   ./scripts/up.sh
EOF
