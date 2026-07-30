# ISSUE.md - Active Issues

## 2. Camunda Workflow Was Never Actually Wired Up (FOUND 2026-07-30, FIX IN PROGRESS)

**Symptom**: `scripts/up.sh` timing out during manual testing led to a broader review of the
project against `PLAN.md`. That review found PLAN.md's checkmarks reflected "the artifact exists"
(a BPMN file was created, a Camunda client library was added to `build.gradle.kts`) rather than
"this actually works end to end." None of it had been exercised against a live cluster.

**Root Cause(s)** (several independent bugs, all discovered by reading the code, not by running it):

1. `OrderService.processOrder()` does `Thread.sleep(100)` and returns. It never constructs a
   Camunda client or starts a process instance. The `camunda.client.*` properties in
   `application.yml` have nothing consuming them - `build.gradle.kts` only depends on the bare
   `io.camunda:camunda-client-java` library, not its Spring Boot integration
   (`io.camunda:camunda-spring-boot-starter`), so there's no autoconfiguration to turn those
   properties into a bean, and no code anywhere references a `CamundaClient`.

2. `spring-boot-app/src/main/resources/workflows/order-process.bpmn` would fail Zeebe's
   deployment validation if deployed as-is:
   - The `ValidateOrder` service task uses `zeebe:type="rest"`, `zeebe:httpMethod`, and
     `zeebe:httpUrl` as raw XML attributes. None of these are part of the real Zeebe BPMN
     extension schema (verified against the `zeebe-bpmn-moddle` schema and Camunda's Connector
     element templates) - a compliant parser ignores unrecognized attributes, so the task ends up
     with no `zeebe:taskDefinition` at all, which Zeebe requires on every service task.
   - `<bpmn:boundaryEvent>` is nested inside `<bpmn:intermediateCatchEvent>`. Boundary events must
     be direct children of `<bpmn:process>` with an `attachedToRef`, not nested inside another
     event element - this is invalid BPMN 2.0 structure.
   - The boundary event references `errorRef="ValidationError"`, but no `<bpmn:error
     id="ValidationError" .../>` element is defined anywhere in the file.
   - Separately (would still be wrong even if the above were fixed): the webhook URL is
     `http://n8n-service.default.svc.cluster.local:5678/...` - n8n deploys to the `apps`
     namespace, not `default`.

3. `helm-values/camunda-values.yaml` has `connectors.enabled: false`. Even a *correctly written*
   BPMN using the real Camunda REST Connector (`io.camunda:http-json:1`) wouldn't execute, because
   there'd be no Connector Runtime pod subscribed to that job type.

4. `application.yml`'s Zeebe gateway address default was also wrong on its own terms:
   `camunda-poc-zeebe-gateway.camunda.svc.cluster.local:26662` - wrong namespace (Camunda deploys
   to `apps`) and wrong port (confirmed against the `camunda-platform` Helm chart's
   `values.yaml`: `zeebeGateway.service.grpcPort` defaults to `26500`, not `26662`).

**Decision**: fix the Spring Boot → Camunda → n8n integration using Camunda's REST Connector
(`io.camunda:http-json:1`) rather than a hand-rolled Zeebe job worker. Connectors are Camunda's
recommended pattern for exactly this shape of integration (call an HTTP endpoint, map the
response into process variables) and this PoC is meant to inform how the real project gets built,
so it should use the pattern Camunda actually recommends for production rather than the fastest
path to a demo. See `PLAN.md` Phase 2 for the concrete step-by-step fix (enable the Connectors
runtime, rewrite the BPMN with a real `zeebe:taskDefinition`, add the Spring Boot Camunda starter
and the actual process-start call).

**Status**: namespace/port bugs (items 2's URL, item 4) are tracked as part of the Phase 2 BPMN
rewrite since that file needs a structural rewrite regardless of the namespace fix. Item 4's
gateway-address bug has been fixed independently since it also affects the (currently unused)
`CamundaClient` config. Items 1 and 3 are open - see `PLAN.md`.

**Addendum (2026-07-30)**: adding `io.camunda:camunda-spring-boot-starter:8.8.0` (item 1's fix)
surfaced two more bugs in `application.yml`, both caught by actually running `./gradlew bootRun`
locally rather than assuming the config was right:
- `camunda.client.mode: simple` isn't a valid value - `CamundaClientProperties.ClientMode` (in the
  `camunda-spring-boot-starter` source at the 8.8.0 tag) only defines `selfManaged`/`saas`. This
  threw `IllegalStateException: Error while post processing camunda properties` at startup, not a
  silent failure.
- `camunda.client.zeebe.gateway-address` (the property item 4 "fixed" the value of) isn't consumed
  by anything at this client version, and isn't in the starter's legacy-property mapping table
  either (checked `camunda-client-legacy-property-mappings.properties` in the same repo/tag) - the
  current property is the flat `camunda.client.grpc-address`, requiring an absolute URI including
  scheme. Item 4's earlier fix corrected the *value* but not the fact that the *key* was already
  dead.

Both fixed; confirmed with a local `bootRun` that the Spring context now starts cleanly and a real
`zeebeClient` bean is constructed (log: `Creating zeebeClient using zeebeClientConfiguration`).
Note the bean is still the deprecated `ZeebeClient` type, not the newer `CamundaClient` interface
(`ZeebeClient is deprecated and will be removed in version 8.10` - both expose the same command
API for now, e.g. `newCreateInstanceCommand()`). Decided to keep `ZeebeClient` for now since it's
what the starter actually wires up by default at 8.8.0, and track the migration as `PLAN.md`
Phase 8 (upgrade to Camunda 8.10, which is what the real project will run).

**Addendum 2 (2026-07-30)**: wiring `OrderService` to actually call `ZeebeClient` and adding
`@Deployment` to auto-deploy the BPMN surfaced two more bugs, again caught by running the app
locally rather than assuming:
- `camunda.client.rest-address` was never set. BPMN auto-deployment goes over the REST API, not
  gRPC (confirmed via stack trace: `DeployResourceCommandStep2.send()` hit
  `http://localhost:8088`, the `self-managed` mode's REST default), so it silently never had a
  chance to reach the real Zeebe Gateway. Fixed by setting `camunda.client.rest-address` to the
  gateway's REST port (8080, confirmed against the `camunda-platform` chart's
  `zeebeGateway.service.restPort` default).
- `@Deployment`'s startup-time deploy call is synchronous and unconditionally fatal on failure -
  traced into `DeploymentAnnotationProcessor.start()` (`clients/camunda-spring-boot-starter` in
  the `camunda/camunda` repo at the 8.8.0 tag): it calls `commandStep2.send().join()` directly
  inside a `SmartLifecycle` bean's `start()`, with no retry or leniency. If Zeebe's REST gateway
  isn't reachable at the exact moment this app starts, the whole Spring context fails to start and
  the pod crashes - not a degraded/partial startup. Since Camunda can take several minutes to
  become ready and `up.sh` deploys it in parallel with this app (no ordering dependency between
  them today), this app would crash-loop repeatedly on every fresh cluster bring-up. Fixed with a
  `wait-for-zeebe-gateway` initContainer in `hello-observability-app.yaml` that blocks pod startup
  until the gateway's REST port is reachable, rather than relying on Kubernetes'
  crash-loop-backoff to eventually get there.

**Affected Components**:
- `spring-boot-app/src/main/java/com/helloobservability/OrderService.java`
- `spring-boot-app/src/main/resources/workflows/order-process.bpmn`
- `spring-boot-app/build.gradle.kts`
- `helm-values/camunda-values.yaml`

---

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
