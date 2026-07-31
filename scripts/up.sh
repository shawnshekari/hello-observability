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
#
# ============================================================================
# Parallel execution model
# ============================================================================
# Most of the steps above have no real dependency on each other - they only
# *look* sequential because they were written top to bottom. The actual
# dependency graph is:
#
#   - GSA/IAM setup, GKE cluster creation, and the Spring Boot image
#     build+push don't depend on each other at all.
#   - Everything else needs kubeconfig (i.e. the cluster to exist) and the
#     two namespaces to exist first.
#   - Once that's true: the cert-manager -> OTel Operator -> OTel Collector
#     -> Workload Identity chain, the n8n deploy, and the Camunda install
#     are all independent of each other. The Spring Boot deploy only needs
#     its image pushed (from Phase 1) and the namespace - it does NOT need
#     n8n/Camunda/OTel to be ready, since those are runtime dependencies of
#     the app (needed when it actually processes an order), not deploy-time
#     dependencies.
#
# So this script runs two phases of background jobs instead of one long
# sequential chain:
#
#   Phase 1 (fully independent): gsa, cluster, image
#   Phase 2 (needs kubeconfig+namespaces): otel, n8n, camunda, springboot
#
# Steps *within* a single job stay sequential where there's a real
# dependency (e.g. cert-manager's webhook must be Ready before the OTel
# Operator - which creates a cert-manager Certificate CR - can install).
#
# Each job's output is captured to its own log file so concurrent output
# doesn't interleave into a garbled mess. Live progress can be watched with
# `tail -f "${JOB_LOG_DIR}"/<job>.log` (the path is printed below); on
# failure, the failing job's full log is printed automatically.
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

# n8n requires an owner account before its API accepts any request at all
# (see ISSUE.md #2 addendum) - this PoC creates one non-interactively via
# n8n-import-workflow.js. Not a real secret: n8n has no external exposure
# (ClusterIP only), so this is just a fixed local credential, not something
# that needs GCP Secret Manager treatment for this PoC's threat model.
N8N_OWNER_EMAIL="admin@hello-observability.local"
N8N_OWNER_PASSWORD="HelloObservability2026!"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================================================================
# Helper: background job runner
# ============================================================================
# run_job launches a function in the background with its output captured to
# a log file. wait_job blocks on one job and prints its log only on failure
# (success stays quiet so parallel output doesn't get noisy). wait_jobs waits
# on several jobs and lets *all* of them finish before reporting failure, so
# one early failure doesn't hide a later, unrelated one.
JOB_LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${JOB_LOG_DIR}"' EXIT
declare -A JOB_PIDS=()

run_job() {
  local job_name="$1"; shift
  ("$@") >"${JOB_LOG_DIR}/${job_name}.log" 2>&1 &
  JOB_PIDS["${job_name}"]=$!
  echo "==> [${job_name}] started (pid ${JOB_PIDS[${job_name}]}, log: ${JOB_LOG_DIR}/${job_name}.log)"
}

wait_job() {
  local job_name="$1"
  if wait "${JOB_PIDS[${job_name}]}"; then
    echo "    ✓ [${job_name}] finished"
    return 0
  else
    echo "    ERROR: [${job_name}] failed. Log:"
    sed 's/^/    | /' "${JOB_LOG_DIR}/${job_name}.log"
    return 1
  fi
}

wait_jobs() {
  local failed=0
  for job_name in "$@"; do
    wait_job "${job_name}" || failed=1
  done
  return "${failed}"
}

# ============================================================================
# Helper: validation functions
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

# ============================================================================
# Phase 1 jobs: no shared dependencies (IAM, cluster, image build)
# ============================================================================

job_gsa_setup() {
  echo "==> Ensuring OTel Collector GSA exists with required IAM roles"
  if ! gcloud iam service-accounts describe "${COLLECTOR_GSA}" >/dev/null 2>&1; then
    echo "==> GSA ${COLLECTOR_GSA} not found. Creating it..."
    gcloud iam service-accounts create otel-collector-gsa \
      --display-name="OTel Collector GSA"
  fi

  # Grant GSA roles (idempotent - safe to re-run)
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${COLLECTOR_GSA}" \
    --role="roles/monitoring.metricWriter" >/dev/null 2>&1
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${COLLECTOR_GSA}" \
    --role="roles/cloudtrace.agent" >/dev/null 2>&1
  echo "    ✓ GSA has monitoring.metricWriter and cloudtrace.agent roles"
}

job_cluster_create() {
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
}

job_docker_build_push() {
  # Build the Spring Boot app container image and push it to GCR so the
  # cluster can pull it. This has zero dependency on the cluster itself, so
  # it runs fully in parallel with cluster/IAM setup - it's one of the
  # slowest steps in the whole script and was previously stuck running dead
  # last, after everything else.
  echo "==> Building Spring Boot image"
  cd "${REPO_ROOT}/spring-boot-app"
  docker build -t "${DOCKER_IMAGE}" .

  echo "==> Pushing Spring Boot image to GCR"
  docker push "${DOCKER_IMAGE}"

  if ! gcloud container images describe "${DOCKER_IMAGE}" --quiet >/dev/null 2>&1; then
    echo "    ERROR: Spring Boot image not found in GCR after push"
    return 1
  fi
  echo "    ✓ Spring Boot image pushed to GCR"
}

# ============================================================================
# Phase 2 jobs: need kubeconfig + namespaces to already exist
# ============================================================================

job_otel_stack() {
  # Step: cert-manager (required by OTel Operator)
  #
  # cert-manager manages TLS certificates in K8s. The OTel Operator depends on
  # it for webhook certificate management. We use Helm for easy installation.
  #
  # GKE Autopilot blocks namespace leadership in kube-system, so we override
  # the leader election namespace to cert-manager.
  echo "==> Installing/upgrading cert-manager"
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.14.4 \
    --set installCRDs=true \
    --set global.leaderElection.namespace=cert-manager \
    --wait --timeout 5m
  validate_pod_ready cert-manager "app.kubernetes.io/instance=cert-manager" "cert-manager"

  # Step: OpenTelemetry Operator
  #
  # The OTel Operator provides a Kubernetes CRD (Custom Resource Definition)
  # for managing OTel Collectors declaratively. Instead of applying raw
  # collector YAML, we use the operator to manage the collector lifecycle.
  # It depends on cert-manager (above) for its webhook TLS certs.
  echo "==> Installing/upgrading the OpenTelemetry Operator"
  kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
  kubectl rollout status deployment/opentelemetry-operator-controller-manager \
    -n opentelemetry-operator-system --timeout=120s
  echo "    ✓ OTel Operator is Ready"

  # Step: OTel Collector
  #
  # The OTel Collector is the central hub for telemetry data. It:
  # - Receives OTLP traces from n8n and Spring Boot
  # - Scrapes Prometheus metrics from Zeebe, Operate, and Spring Boot
  # - Exports everything to Google Cloud (Trace + Monitoring)
  #
  # The collector runs in the 'observability' namespace and uses Workload
  # Identity to authenticate with GCP APIs.
  echo "==> Deploying the OTel Collector"
  kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/otel-collector.yaml"
  kubectl rollout status deployment/${COLLECTOR_KSA} -n ${NS_OBSERVABILITY} --timeout=120s
  validate_pod_ready "${NS_OBSERVABILITY}" "app.kubernetes.io/name=${COLLECTOR_KSA}" "OTel Collector"

  # Step: Bind OTel Collector to GCP Service Account (Workload Identity)
  #
  # GKE Autopilot requires Workload Identity for pods to access GCP APIs.
  # The OTel Operator recreates the collector's ServiceAccount on every
  # reconcile, so we must re-annotate it here to maintain the binding.
  #
  # This allows the collector pod to impersonate the GSA and export
  # traces/metrics to GCP without API keys. Requires the GSA from the
  # Phase 1 `gsa` job, which the caller waits on before starting this job.
  echo "==> Re-binding collector ServiceAccount to ${COLLECTOR_GSA} (Workload Identity)"
  gcloud iam service-accounts add-iam-policy-binding \
    "${COLLECTOR_GSA}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NS_OBSERVABILITY}/${COLLECTOR_KSA}]" >/dev/null 2>&1 || true

  kubectl annotate serviceaccount "${COLLECTOR_KSA}" -n ${NS_OBSERVABILITY} \
    iam.gke.io/gcp-service-account="${COLLECTOR_GSA}" --overwrite

  # Verify annotation was applied
  ANNOTATION=$(kubectl get sa "${COLLECTOR_KSA}" -n ${NS_OBSERVABILITY} -o jsonpath="{.metadata.annotations.iam\.gke\.io/gcp-service-account}")
  if [ "${ANNOTATION}" != "${COLLECTOR_GSA}" ]; then
    echo "    ERROR: Workload Identity annotation not applied correctly"
    return 1
  fi
  echo "    ✓ Workload Identity annotation verified"

  # Restart collector pod to pick up the new identity binding
  echo "==> Restarting collector pod to pick up the identity binding"
  kubectl delete pod -n ${NS_OBSERVABILITY} -l app.kubernetes.io/name=${COLLECTOR_KSA} --ignore-not-found
  kubectl rollout status deployment/${COLLECTOR_KSA} -n ${NS_OBSERVABILITY} --timeout=120s
}

job_n8n_deploy() {
  # n8n is a workflow automation tool. We use it to:
  # - Receive order validation requests from Camunda
  # - Validate order data (quantity, format, etc.)
  # - Return validation results to Camunda
  #
  # n8n is configured with OpenTelemetry enabled, so it exports traces
  # to our OTel Collector automatically. It only needs the 'apps' namespace
  # to exist, not the OTel Collector to be up yet - its OTel exporter will
  # just retry until the collector is reachable.
  echo "==> Deploying n8n"
  kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/n8n.yaml"

  # kubectl rollout status blocks on the Deployment's readinessProbe
  # (httpGet /healthz), so this alone is a correct, race-free readiness
  # gate - no need to separately curl the pod from outside the cluster.
  echo "==> Waiting for n8n to be ready..."
  kubectl rollout status deployment/n8n -n ${NS_APPS} --timeout=120s
  validate_pod_ready "${NS_APPS}" "app=n8n" "n8n"

  # Import n8n workflow. Earlier versions of this step used wget+grep piped
  # through several layers of shell quoting, which turned out to be broken
  # in multiple ways (busybox wget has no --method flag at all, so it could
  # never have PATCH/PUT'd the activation call; multi-layer shell escaping
  # mangled the JSON body). Copying real files into the pod and running a
  # committed Node script sidesteps both problems entirely - see
  # n8n-import-workflow.js and ISSUE.md #2 addendum for the full history
  # (n8n's :latest tag also turned out to require an owner account before
  # any API call works at all, which the script also handles).
  echo "==> Importing n8n order validation workflow"
  N8N_POD=$(kubectl get pods -n ${NS_APPS} -l app=n8n -o jsonpath='{.items[0].metadata.name}')
  kubectl cp "${REPO_ROOT}/n8n/order-validation.json" "${NS_APPS}/${N8N_POD}:/tmp/order-validation.json"
  kubectl cp "${REPO_ROOT}/scripts/n8n-import-workflow.js" "${NS_APPS}/${N8N_POD}:/tmp/n8n-import-workflow.js"
  kubectl exec "${N8N_POD}" -n ${NS_APPS} -- node /tmp/n8n-import-workflow.js \
    /tmp/order-validation.json "${N8N_OWNER_EMAIL}" "${N8N_OWNER_PASSWORD}"
}

job_camunda_deploy() {
  # Camunda 8 (Zeebe) is our workflow orchestration engine. It:
  # - Executes BPMN workflows
  # - Calls n8n for order validation
  # - Exports metrics to OTel Collector (scraped via Prometheus)
  #
  # We use Helm chart 11.12.3 (Camunda 8.6.x) to avoid kernel issues on
  # Autopilot. Operate requires Elasticsearch as its data backend (its
  # schema-migration init container fails outright without it - see
  # ISSUE.md #2 addendum), so a single-node Elasticsearch is enabled via
  # camunda-values.yaml. That requires this ComputeClass to already exist -
  # see k8s-infrastructure/elasticsearch-computeclass.yaml for why (GKE
  # Autopilot's vm.max_map_count constraint). ComputeClass is cluster-scoped
  # (not namespaced), so applying it is idempotent regardless of run order.
  echo "==> Applying Elasticsearch ComputeClass"
  kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/elasticsearch-computeclass.yaml"

  # This only needs the 'apps' namespace, not n8n/OTel to be ready.
  echo "==> Deploying Camunda 8 (Zeebe)"
  helm upgrade --install camunda-poc camunda/camunda-platform \
    --namespace ${NS_APPS} \
    --create-namespace \
    --version 11.12.3 \
    -f "${REPO_ROOT}/helm-values/camunda-values.yaml" \
    --wait --timeout 10m

  echo "==> Waiting for Zeebe to be ready..."
  kubectl rollout status statefulset/camunda-poc-zeebe -n ${NS_APPS} --timeout=120s
  kubectl rollout status deployment/camunda-poc-zeebe-gateway -n ${NS_APPS} --timeout=120s
  validate_pod_ready "${NS_APPS}" "app.kubernetes.io/name=zeebe" "Zeebe Broker" 60
  validate_pod_ready "${NS_APPS}" "app.kubernetes.io/name=zeebe-gateway" "Zeebe Gateway" 60

  # Best-effort only: like the old n8n/Spring Boot checks, this curls a pod
  # IP directly from wherever this script runs, which only succeeds if that
  # happens to be inside the cluster's VPC. It's a non-fatal warning either
  # way, gated on the rollout/pod-ready checks above for real signal.
  echo "==> Validating Zeebe Gateway connectivity..."
  ZEEBE_GW_POD=$(kubectl get pods -n ${NS_APPS} -l app.kubernetes.io/name=zeebe-gateway -o jsonpath='{.items[0].metadata.name}')
  ZEEBE_GW_IP=$(kubectl get pod "${ZEEBE_GW_POD}" -n ${NS_APPS} -o jsonpath='{.status.podIP}')
  # 9600 is the Zeebe Gateway's actuator/management port (verified against
  # the camunda-platform Helm chart's values.yaml - zeebeGateway.service.httpPort).
  if curl -sf --connect-timeout 3 --max-time 5 "http://${ZEEBE_GW_IP}:9600/actuator/health" >/dev/null 2>&1; then
    echo "    ✓ Zeebe Gateway health check passed"
  else
    echo "    INFO: Zeebe Gateway health endpoint not reachable from this machine (expected unless running inside the cluster's VPC)"
  fi
}

job_springboot_deploy() {
  # The Spring Boot app is our order service. It:
  # - Exposes REST API for creating orders
  # - Calls Camunda to start workflow instances
  # - Exports custom business metrics via Micrometer/OTel
  # - Uses OpenTelemetry Java agent for automatic instrumentation
  #
  # Deploy-time dependencies are just the pushed image (Phase 1 `image` job,
  # awaited by the caller before this job starts) and the 'apps' namespace.
  # It does NOT need Camunda/n8n/OTel to be ready to deploy successfully -
  # those only matter once it actually processes an order.
  echo "==> Deploying Spring Boot App"
  kubectl apply -f "${REPO_ROOT}/k8s-infrastructure/hello-observability-app.yaml"

  # kubectl rollout status blocks on the Deployment's readinessProbe
  # (httpGet /actuator/health), so this alone is a correct, race-free
  # readiness gate - no need to separately curl the pod from outside the
  # cluster the way this script used to.
  echo "==> Waiting for Spring Boot app to be ready..."
  kubectl rollout status deployment/hello-observability-app -n ${NS_APPS} --timeout=120s
  validate_pod_ready "${NS_APPS}" "app=hello-observability-app" "Spring Boot App"
}

# ============================================================================
# Pre-flight
# ============================================================================
echo "==> Using project ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

# ============================================================================
# Phase 1: IAM setup, cluster creation, and image build+push run in parallel
# ============================================================================
# None of these three depend on each other.
echo ""
echo "==> Phase 1: GSA/IAM setup, cluster creation, and Spring Boot image build+push (parallel)"
run_job gsa    job_gsa_setup
run_job cluster job_cluster_create
run_job image  job_docker_build_push

# Everything from here on needs kubeconfig, so block on the cluster job.
# The gsa and image jobs keep running in the background regardless.
wait_job cluster
echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}"

# Needed before the Workload Identity rebind inside job_otel_stack. Cheap,
# so just resolve it now rather than threading it through Phase 2.
wait_job gsa

# Helm repo add/update touches a shared local repo config file
# (~/.config/helm/repositories.yaml), so it must NOT run concurrently across
# jobs - do it once, here, before forking Phase 2.
echo "==> Adding Helm repositories"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add camunda https://helm.camunda.io >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> Creating namespaces"
kubectl create namespace "${NS_OBSERVABILITY}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${NS_APPS}" --dry-run=client -o yaml | kubectl apply -f -

# ============================================================================
# Phase 2: OTel stack, n8n, Camunda, and Spring Boot run in parallel
# ============================================================================
echo ""
echo "==> Phase 2: OTel stack, n8n, Camunda, and Spring Boot deploy (parallel)"
run_job otel    job_otel_stack
run_job n8n     job_n8n_deploy
run_job camunda job_camunda_deploy

# Spring Boot's Deployment needs the pushed image - wait for Phase 1's
# `image` job (the other three jobs above keep running concurrently while
# we wait) before starting it.
wait_job image
run_job springboot job_springboot_deploy

if ! wait_jobs otel n8n camunda springboot; then
  echo ""
  echo "==> One or more Phase 2 jobs failed. See logs above."
  exit 1
fi

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
