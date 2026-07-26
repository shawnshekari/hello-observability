# ISSUE.md - Active Issues

## 1. Metrics Export Permission Denied (RESOLVED 2026-07-26)

**Symptom**: OTel Collector `googlecloud` exporter failing to send metrics to Cloud Monitoring.

**Error Logs**:
```
rpc error: code = PermissionDenied desc = Permission monitoring.metricDescriptors.create denied (or the resource may not exist).
rpc error: code = PermissionDenied desc = Permission monitoring.timeSeries.create denied (or the resource may not exist).
```

**Root Cause**: `hellootelworld.svc.id.goog` is **not** a service account — it's the GKE Workload
Identity pool identifier for this project (`gcloud container clusters describe ... --format='value(workloadIdentityConfig.workloadPool)'`).
GKE Autopilot has Workload Identity mandatory and always on. The collector pod ran under the
Kubernetes ServiceAccount `cluster-collector-collector` (namespace `default`, auto-created by the
OTel Operator), which had **no** `iam.gke.io/gcp-service-account` annotation binding it to any
Google Service Account. An unbound KSA under Workload Identity does not fall back to the node's
compute service account — it authenticates as an identity-pool member with zero IAM grants. That's
why the error persisted even though `705534244335-compute@developer.gserviceaccount.com` already
had `roles/monitoring.metricWriter` and `roles/monitoring.admin`: that service account was never
actually used by the pod.

The previous fix attempt in this doc (granting roles directly to a member named
`serviceAccount:hellootelworld.svc.id.goog`) does not work — that identifier is only valid in the
compound form `serviceAccount:PROJECT_ID.svc.id.goog[NAMESPACE/KSA_NAME]`, and only as the member of
a `roles/iam.workloadIdentityUser` binding on a specific GSA resource, not as a direct grantee of
project-level roles.

**Fix applied**: Standard GKE Workload Identity wiring — create a dedicated GSA, grant it the roles
the collector needs, bind the KSA to it, and annotate the KSA.
```bash
# 1. Dedicated Google Service Account
gcloud iam service-accounts create otel-collector-gsa \
  --project=hellootelworld \
  --display-name="OTel Collector"

# 2. Grant it the roles the googlecloud exporter needs (metrics + traces)
gcloud projects add-iam-policy-binding hellootelworld \
  --member="serviceAccount:otel-collector-gsa@hellootelworld.iam.gserviceaccount.com" \
  --role="roles/monitoring.metricWriter"

gcloud projects add-iam-policy-binding hellootelworld \
  --member="serviceAccount:otel-collector-gsa@hellootelworld.iam.gserviceaccount.com" \
  --role="roles/cloudtrace.agent"

# 3. Allow the KSA to impersonate the GSA
gcloud iam service-accounts add-iam-policy-binding \
  otel-collector-gsa@hellootelworld.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:hellootelworld.svc.id.goog[default/cluster-collector-collector]"

# 4. Annotate the KSA so GKE issues tokens for the GSA
kubectl annotate serviceaccount cluster-collector-collector -n default \
  iam.gke.io/gcp-service-account=otel-collector-gsa@hellootelworld.iam.gserviceaccount.com
```

**Verification**: After granting permissions, restart the collector pod:
```bash
kubectl delete pod -n default -l app.kubernetes.io/name=cluster-collector-collector
```
Expect a transient `Unauthenticated ... iam.serviceAccounts.getAccessToken denied` for the first
~1-2 minutes after the binding is created (IAM propagation delay) — this clears on its own.

**Caveat / follow-up**: The KSA `cluster-collector-collector` is owned by the `OpenTelemetryCollector`
CR (`ownerReferences` points at it) and auto-created by the OTel Operator on every reconcile. The
`iam.gke.io/gcp-service-account` annotation survived a pod restart/reconcile in this instance, but if
a future config change to `otel-collector.yaml` causes the operator to recreate the SA and strip the
annotation, the durable fix is to pre-create a KSA with the annotation already set and reference it
via `spec.serviceAccount` in the `OpenTelemetryCollector` CR instead of relying on the operator's
auto-created one.

Also consider removing the now-unnecessary/overly-broad `roles/monitoring.admin` grant on
`705534244335-compute@developer.gserviceaccount.com` since it was never the identity actually in use.

**Affected Components**:
- OTel Collector pod: `cluster-collector-collector-*`
- Namespace: `default`
- Metrics pipeline: `prometheus` receiver -> `googlecloud` exporter
- Scrape target: Camunda Zeebe broker metrics
