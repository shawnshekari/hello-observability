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

# Namespace configuration
# - observability: OTel Collector (telemetry aggregation)
# - apps: n8n, Camunda 8, Spring Boot (application workloads)
NS_OBSERVABILITY="observability"
NS_APPS="apps"

# Image configuration for Spring Boot app
DOCKER_IMAGE="gcr.io/${PROJECT_ID}/hello-observability-app"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================================================================
# Helper: Validation functions
# ============================================================================
validate_pod_ready() {
  local namespace="$1"
  local label="$2"
  local name="$3"
  local retries="${4:-30}"
  local count
  count=$(kubectl get pods -n "${namespace}" -l "${label}" --no-headers 2>/dev/null \
    | awk '$1==NAME && $2=="1/1" && $3=="Running" {print}' | wc -l)
  local i=0
  while [ "${count}" -eq 0 ] && [ "${i}" -lt "${retries}" ]; do
    echo "    Waiting for ${name} to be Running (attempt $((i+1))/${retries})..."
    sleep 5
    i=$((i+1))
    count=$(kubectl get pods -n "${namespace}" -l "${label}" --no-headers 2>/dev/null \
      | awk '{if($2=="1/1" && $3=="Running") print}' | wc -l)
  done
  if [ "${count}" -eq 0 ]; then
    echo "    ERROR: ${name} failed to become Ready after ${retries} attempts"
    kubectl get pods -n "${namespace}" -l "${label}" -o wide
    return 1
  fi
  echo "    ✓ ${name} is Running"
}

validate_http_endpoint() {
  local url="$1"
  local name="$2"
  local retries="${3:-10}"
  local i=0
  while [ "${i}" -lt "${retries}" ]; do
    if curl -sf "${url}" >/dev/null 2>&1; then
      echo "    ✓ ${name} health check passed"
      return 0
    fi
    echo "    Waiting for ${name} to respond (attempt $((i+1))/${retries})..."
    sleep 3
    i=$((i+1))
  done
  echo "    ERROR: ${name} failed health check after ${retries} attempts"
  return 1
}

# ============================================================================
# Pre-flight checks
# ============================================================================
echo "==> Using project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

# Check if GSA exists (required for Workload Identity)
if ! gcloud iam service-accounts describe "${COLLECTOR_GSA}" >/dev/null 2>&1; then
  echo "==> GSA ${COLLECTOR_GSA} not found. Creating it..."
  gcloud iam service-accounts create otel-collector-gsa \
    --display-name="OTel Collector GSA"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount=${COLLECTOR_GSA}" \
    --role="roles/monitoring.metricWriter"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount=${COLLECTOR_GSA}" \
    --role="roles/cloudtrace.agent"
  echo "    ✓ GSA created with monitoring.metricWriter and cloudtrace.agent roles"
fi

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

# Validate cert-manager is running
validate_pod_ready cert-manager "app.kubernetes.io/instance=cert-manager" "cert-manager"

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
echo "    ✓ OTel Operator is Ready"

# ============================================================================
# Step 4: Deploy OTel Collector
# ============================================================================
# The OTel Collector is the central hub for telemetry data. It:
# - Receives OTLP traces from n8n and Spring Boot
# - Scrapes Prometheus metrics from Zeebe, Operate, and Spring Boot
# - Exports everything to Google Cloud (Trace + Monitoring)
#
# The collector runs in the 'observability' namespace and uses Workload Identity
# to authenticate with GCP APIs.
echo "==> Deploying the OTel Collector"
kubectl create namespace "${NS_OBSERVABILITY}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/otel-collector.yaml"
kubectl rollout status deployment/${COLLECTOR_KSA} -n ${NS_OBSERVABILITY} --timeout=120s

# Validate OTel Collector is running
validate_pod_ready "${NS_OBSERVABILITY}" "app.kubernetes.io/name=${COLLECTOR_KSA}" "OTel Collector"

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

# Bind GSA to KSA (idempotent)
gcloud iam service-accounts add-iam-policy-binding \
  "${COLLECTOR_GSA}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NS_OBSERVABILITY}/${COLLECTOR_KSA}" >/dev/null 2>&1 || true

kubectl annotate serviceaccount "${COLLECTOR_KSA}" -n ${NS_OBSERVABILITY} \
  iam.gke.io/gcp-service-account="${COLLECTOR_GSA}" --overwrite

# Verify annotation was applied
ANNOTATION=$(kubectl get sa "${COLLECTOR_KSA}" -n ${NS_OBSERVABILITY} -o jsonpath='{.metadata.annotations["iam\.gke\.io/gcp-service-account"]}')
if [ "${ANNOTATION}" != "${COLLECTOR_GSA}" ]; then
  echo "    ERROR: Workload Identity annotation not applied correctly"
  exit 1
fi
echo "    ✓ Workload Identity annotation verified"

# Restart collector pod to pick up the new identity binding
echo "==> Restarting collector pod to pick up the identity binding"
kubectl delete pod -n ${NS_OBSERVABILITY} -l app.kubernetes.io/name=${COLLECTOR_KSA} --ignore-not-found
kubectl rollout status deployment/${COLLECTOR_KSA} -n ${NS_OBSERVABILITY} --timeout=120s

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
kubectl create namespace "${NS_APPS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/n8n.yaml"

# Wait for n8n to be ready before importing workflow
echo "==> Waiting for n8n to be ready..."
kubectl rollout status deployment/n8n -n ${NS_APPS} --timeout=120s
validate_pod_ready "${NS_APPS}" "app=n8n" "n8n"

# Validate n8n health endpoint
validate_http_endpoint "http://$(kubectl get pod -n ${NS_APPS} -l app=n8n -o jsonpath='{.items[0].status.podIP}'):5678/healthz" "n8n" 5

# Import n8n workflow
echo "==> Importing n8n order validation workflow"
N8N_POD=$(kubectl get pods -n ${NS_APPS} -l app=n8n -o jsonpath='{.items[0].metadata.name}')
N8N_WORKFLOW=$(cat "${REPO_ROOT}/n8n/order-validation.json")
kubectl exec "${N8N_POD}" -n ${NS_APPS} -- sh -c "echo '${N8N_WORKFLOW}' | curl -s -X POST http://localhost:5678/api/v1/workflows -H 'Content-Type: application/json' -d @-"

# Activate the workflow
WORKFLOW_ID=$(kubectl exec "${N8N_POD}" -n ${NS_APPS} -- sh -c "curl -s http://localhost:5678/api/v1/workflows | jq -r '.workflows[] | select(.name==\"Order Validation\") | .id'")
kubectl exec "${N8N_POD}" -n ${NS_APPS} -- sh -c "curl -s -X PUT http://localhost:5678/api/v1/workflows/${WORKFLOW_ID}/activate"
echo "    ✓ n8n workflow imported and activated (id: ${WORKFLOW_ID})"

# ============================================================================
# Step 7: Deploy Camunda 8 (Zeebe workflow engine)
# ============================================================================
# Camunda 8 (Zeebe) is our workflow orchestration engine. It:
# - Executes BPMN workflows
# - Calls n8n for order validation
# - Exports metrics to OTel Collector (scraped via Prometheus)
#
# We use Helm chart 11.12.3 (Camunda 8.6.x) to avoid kernel issues on
# Autopilot. Only Zeebe + Gateway + Operate are deployed (no Elasticsearch).
echo "==> Deploying Camunda 8 (Zeebe)"
helm repo add camunda https://helm.camunda.io >/dev/null
helm repo update >/dev/null
helm upgrade --install camunda-poc camunda/camunda-platform \
  --namespace ${NS_APPS} \
  --create-namespace \
  --version 11.12.3 \
  -f "${REPO_ROOT}/helm-values/camunda-values.yaml" \
  --wait --timeout 10m

# Wait for Zeebe to be ready
echo "==> Waiting for Zeebe to be ready..."
kubectl rollout status statefulset/camunda-poc-zeebe -n ${NS_APPS} --timeout=120s
kubectl rollout status deployment/camunda-poc-zeebe-gateway -n ${NS_APPS} --timeout=120s
validate_pod_ready "${NS_APPS}" "app.kubernetes.io/name=zeebe" "Zeebe Broker" 60
validate_pod_ready "${NS_APPS}" "app.kubernetes.io/name=zeebe-gateway" "Zeebe Gateway" 60

# Validate Zeebe Gateway is accepting connections (gRPC health check)
echo "==> Validating Zeebe Gateway connectivity..."
ZEEBE_GW_POD=$(kubectl get pods -n ${NS_APPS} -l app.kubernetes.io/name=zeebe-gateway -o jsonpath='{.items[0].metadata.name}')
ZEEBE_GW_IP=$(kubectl get pod "${ZEEBE_GW_POD}" -n ${NS_APPS} -o jsonpath='{.status.podIP}')
if curl -sf "http://${ZEEBE_GW_IP}:26501/actuator/health" >/dev/null 2>&1; then
  echo "    ✓ Zeebe Gateway health check passed"
else
  echo "    WARNING: Zeebe Gateway health endpoint not reachable (may need more time to initialize)"
fi

# ============================================================================
# Step 8: Build and push Spring Boot image
# ============================================================================
# Build the Spring Boot app container image and push it to GCR so the
# cluster can pull it. Uses Docker Buildx for multi-arch if available.
echo "==> Building Spring Boot image"
cd "${REPO_ROOT}/spring-boot-app"
docker build -t "${DOCKER_IMAGE}" .

echo "==> Pushing Spring Boot image to GCR"
docker push "${DOCKER_IMAGE}"

# Validate image was pushed successfully
if gcloud container images describe "${DOCKER_IMAGE}" --quiet >/dev/null 2>&1; then
  echo "    ✓ Spring Boot image pushed to GCR"
else
  echo "    ERROR: Spring Boot image not found in GCR after push"
  exit 1
fi
cd "${REPO_ROOT}"

# ============================================================================
# Step 9: Deploy Spring Boot App
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
kubectl rollout status deployment/hello-observability-app -n ${NS_APPS} --timeout=120s
validate_pod_ready "${NS_APPS}" "app=hello-observability-app" "Spring Boot App"

# Validate Spring Boot health endpoint
validate_http_endpoint "http://$(kubectl get pod -n ${NS_APPS} -l app=hello-observability-app -o jsonpath='{.items[0].status.podIP}'):8080/actuator/health" "Spring Boot App" 15

# ============================================================================
# Final validation: Check OTel Collector is exporting
# ============================================================================
echo "==> Validating OTel Collector is exporting telemetry..."
sleep 10
COLLECTOR_LOGS=$(kubectl logs -n ${NS_OBSERVABILITY} -l app.kubernetes.io/name=${COLLECTOR_KSA} --tail=20 2>/dev/null || true)
if echo "${COLLECTOR_LOGS}" | grep -qi "exported\|sent\|pushed"; then
  echo "    ✓ OTel Collector is exporting telemetry to Google Cloud"
else
  echo "    INFO: OTel Collector is running. Check logs for export status:"
  echo "    kubectl logs -n ${NS_OBSERVABILITY} -l app.kubernetes.io/name=${COLLECTOR_KSA} --tail=50"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "==> All components deployed. Current pods:"
kubectl get pods -n ${NS_OBSERVABILITY}
kubectl get pods -n ${NS_APPS}

cat <<EOF

==> Deployment complete! Verify everything is working:

1. Check OTel Collector logs for successful exports:
   kubectl logs -n ${NS_OBSERVABILITY} -l app.kubernetes.io/name=cluster-collector-collector --tail=50

2. Test n8n webhook (port-forward first):
   kubectl port-forward svc/n8n-service 5678:5678 -n ${NS_APPS}
   curl -X POST http://localhost:5678/webhook/order-validation \
     -H "Content-Type: application/json" \
     -d '{"orderId": "test-1", "itemName": "Widget", "quantity": 2}'

3. Test Spring Boot app (port-forward first):
   kubectl port-forward svc/hello-observability-app 8080:80 -n ${NS_APPS}
   curl -X POST http://localhost:8080/orders \
     -H "Content-Type: application/json" \
     -d '{"orderId": "test-1", "itemName": "Widget", "quantity": 2}'

4. View traces in Google Cloud Console:
   https://console.cloud.google.com/traces?project=hellootelworld

5. View metrics in Google Cloud Console:
   https://console.cloud.google.com/monitoring?project=hellootelworld

If Zeebe is stuck in CrashLoop from stale Raft state (e.g. after a partial
teardown), wipe it and reinstall:
   kubectl delete pvc --all -n ${NS_APPS}
   helm uninstall camunda-poc -n ${NS_APPS}
   ./scripts/up.sh
EOF
