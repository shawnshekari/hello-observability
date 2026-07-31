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

**Addendum 3 (2026-07-30)**: the first real deployment against a live cluster (everything above
was verified locally/statically, without a running cluster) surfaced a bug none of that could have
caught: Camunda Operate's `migration` init container crash-looped with
`java.net.ConnectException: Connection refused` against Elasticsearch. Root cause:
`helm-values/camunda-values.yaml` had `operate.enabled: true` alongside
`global.elasticsearch.enabled: false` / `elasticsearch.enabled: false` - but Operate's
schema-migration step is a hard dependency on Elasticsearch, not an optional one. That combination
can never work; `helm install --wait` would only ever time out after the full 10 minutes (confirmed
- it did: `Error: context deadline exceeded`), no amount of waiting fixes it.

Enabling Elasticsearch on GKE Autopilot has its own wrinkle: Elasticsearch needs the host kernel's
`vm.max_map_count` raised well above GKE's default, and the chart's bundled Bitnami Elasticsearch
subchart handles this via a `sysctlImage` init container that runs `privileged: true` /
`runAsUser: 0` - which Autopilot's admission control rejects outright, unlike GKE Standard where
this is the normal approach. Fixed with:
- `k8s-infrastructure/elasticsearch-computeclass.yaml`: a GKE `ComputeClass`
  (`cloud.google.com/v1`), the Autopilot-native mechanism for node-level kernel settings -
  `vm.max_map_count: 1048576` (not the older `262144`; confirmed via the chart's own
  `charts/elasticsearch/values.yaml` that the bundled image is `8.18.0`, and Elastic's own guidance
  is 1048576 for 8.16+). Pods opt in via `nodeSelector: cloud.google.com/compute-class:
  elasticsearch`, a label GKE applies automatically to nodes of that class.
- `helm-values/camunda-values.yaml`: `sysctlImage.enabled: false` to disable the now-redundant
  (and Autopilot-fatal) privileged init container, since the ComputeClass already handles it at the
  node level.
- Sized Elasticsearch down hard from the chart's default (`master.replicaCount: 3`) to a single
  node (`master.replicaCount: 1`, `data.replicaCount: 0`, combined master+data role) - a 3-node ES
  cluster plus a dedicated ComputeClass-provisioned node pool on top of everything else already
  running would have been a real, avoidable cost increase for what's still just a PoC.

Every field used above was checked against the live cluster's actual CRD schema via `kubectl
explain computeclass...` (not assumed from documentation, which was sometimes ECK-operator-specific
rather than applicable to this Helm-chart-based deployment) before writing the manifest, and the
full change was verified with `helm template` (confirmed no privileged containers render) and
`helm install --dry-run=server` (passed real validation) before touching the live cluster.

**Addendum 4 (2026-07-30)**: with Camunda finally healthy, n8n turned out to have its own
independent set of live-only bugs, all traceable to `n8n.yaml` pinning
`docker.n8n.io/n8nio/n8n:latest` while `n8n/order-validation.json` was authored against a much
older n8n version - the deployed instance is 2.32.6:
- n8n now requires completing owner setup (`POST /rest/owner/setup`) and a session login
  (`POST /rest/login`) before *any* API call succeeds - previously the workflow API was
  unauthenticated. Every `/rest/` and even `/api/v1/` call returned 401 until this was done.
- The Webhook node had no `responseMode` set, so it defaulted to `onReceived` - acknowledging the
  HTTP request immediately (`{"message":"Workflow was started"}`) rather than waiting for the
  workflow to finish and returning its actual output. Needed `responseMode: "lastNode"` +
  `responseData: "firstEntryJson"`.
- The "Valid Order"/"Invalid Order" Set nodes were declared `typeVersion: 1`, which n8n's source
  (`packages/nodes-base/nodes/Set/Set.node.ts`) maps to `SetV1` - an implementation expecting a
  completely different parameter shape (`values.boolean`/`values.string` arrays) than what the
  file actually provided (`assignments.assignments`, the V2/V3 schema). `SetV1` found nothing to
  set and silently passed its input through unchanged - the webhook returned 200 with no error,
  just the wrong data, which is why this took inspecting n8n's own source to diagnose rather than
  reading an error message. Bumped to `typeVersion: 3.4` (mapped to `SetV2`, which the file's
  existing parameter shape already matches - no restructuring needed, just the version number).
- Even after that fix, "Check Quantity" always took the false branch regardless of input. Its
  condition read `={{ $json.quantity }}`, but the Webhook node nests the actual request payload
  under `.body` (confirmed from the node's own raw output shape) - so `value1` was always
  `undefined`, and `largerEqual`'s `(value1 || 0) >= (value2 || 0)` always evaluated `0 >= 1` =
  false. Fixed to `$json.body.quantity`. This one wasn't a version-drift issue like the others -
  just a pre-existing authoring bug in the original workflow that happened to never surface until
  the workflow could actually execute for the first time tonight.
- Also found (not the active bug, but real): both Set nodes had a duplicate `parameters` JSON key
  - a dead `{"responseMode":"responseJson","options":{}}` block that JSON parsing silently
  discards in favor of the second occurrence. Removed.
- `up.sh`'s import/activation logic was independently broken on top of all of the above: busybox
  wget (the n8n image has no curl/jq) has no `--method` flag whatsoever, so the old
  `--method=PUT .../activate` call could never have succeeded even against a compatible n8n
  version - confirmed by testing it directly (`wget: unrecognized option: method=PUT`). And piping
  the workflow JSON through `echo '...' | wget --post-data=@-` across multiple layers of shell
  quoting (this script -> `kubectl exec` -> remote `sh` -> `echo`) corrupted the JSON body
  (`ResponseError: Failed to parse request body` in n8n's own logs) even once auth was fixed.
  Replaced entirely: `scripts/n8n-import-workflow.js` (new, committed) is `kubectl cp`'d into the
  pod alongside the workflow JSON and run with the pod's own Node.js (`node --version` confirmed
  v24, has built-in `fetch` - no method restrictions, no shell-quoting layers to fight). Handles
  owner setup, login, idempotent replacement of any existing same-named workflow, import, and
  activation, all via real HTTP calls instead of shell-escaped one-liners.
- Verified live end-to-end after all fixes: `POST /webhook/order-validation` with `quantity: 2`
  returns `{"valid":true,"message":"Order validated successfully"}`; `quantity: 0` returns
  `{"valid":false,"message":"Order quantity must be at least 1"}` - both branches correct.

**Addendum 5 (2026-07-30)**: with everything else working, Cloud Logging showed the OTel
Collector logging a `Failed to scrape Prometheus endpoint` warning every 15s for
`hello-observability-app.apps.svc.cluster.local:80` (HTTP 404). Root cause: `build.gradle.kts`
never added `micrometer-registry-prometheus` - so `/actuator/prometheus` never existed on the app
at all (confirmed: `GET /actuator` lists only `health`/`info`, regardless of `prometheus` being
named in `management.endpoints.web.exposure.include`, since the exposure list can only reveal
endpoints that already exist). Not a real gap, though - Spring Boot's metrics already reach Cloud
Monitoring via the working `management.metrics.export.otlp` push path. Removed the redundant,
always-broken scrape job from `otel-collector.yaml` and the now-misleading `prometheus` mention
from `application.yml`'s exposure list, rather than adding a second collection path that was never
needed. Confirmed live: collector restarted and its startup log now only registers the
`camunda-zeebe`/`camunda-operate` scrape jobs.

**Addendum 6 (2026-07-30)**: despite the "verified live end-to-end" claim above, real orders
posted through the app started producing Zeebe **incidents** on `Gateway_OrderValid`, visible in
Operate as a red badge on the `ValidateOrder`/boundary-event area. Root cause traced with the
authoritative source data, not guessed: since Operate's own REST API needs CSRF handling beyond a
simple session cookie (its login response sets a `X-CSRF-TOKEN` *response header*, distinct from a
same-named cookie it also sets - the frontend reads the header value and echoes it back on
subsequent requests; this wasn't discovered in time to be worth pursuing further), the incident
document was read directly from the `operate-incident-*` Elasticsearch index Operate itself is
backed by:

```
errorType: EXTRACT_VALUE_ERROR
errorMessage: Expected result of the expression 'validationResult.valid' to be 'BOOLEAN', but was
  'NULL'. ... No context entry found with key 'valid'. Available keys: 'status', 'headers',
  'body', 'reason'
```

The BPMN's `Gateway_OrderValid` condition read `validationResult.valid`, on the (wrong)
assumption that `resultExpression`'s mapped output would nest inside the `resultVariable`-named
variable. Traced into `ConnectorResultHandler.createOutputVariables` in the `camunda/connectors`
repo: `resultVariable` and `resultExpression` are independent - `resultVariable` stores the raw
response object under its own name (exactly the `status`/`headers`/`body`/`reason` shape seen in
the error), while `resultExpression`'s mapped keys (`valid`, `message`) are `putAll`'d as their
own **top-level** process variables, not nested under `resultVariable`'s name. Fixed the condition
to just `=valid`. Kept `resultVariable` (the raw response is genuinely useful to have visible in
Operate when troubleshooting exactly this kind of thing - which is exactly what happened here).

Since the BPMN is bundled into the Spring Boot image at build time (`@Deployment` loads it from
the classpath), fixing the source file alone doesn't change what's running - rebuilt and pushed
the image, then deleted the pod to force a fresh pull. The new deployment logged
`Deployed: <order-process:2>` (Zeebe versioned it automatically). Verified via the same
Elasticsearch-direct approach: a fresh order's `operate-flownode-instance` records show
`StartEvent_1 -> ValidateOrder -> Gateway_OrderValid -> CompleteOrder`, all `COMPLETED`, no new
incident - confirming the full chain now genuinely completes, not just "the HTTP calls succeeded"
as the earlier addendum had actually verified.

**Addendum 7 (2026-07-30)**: asked to set up a Cloud Monitoring metric for the order process,
which surfaced that `orders.created`/`orders.failed`/`orders.latency` (the app's own business
metrics from `OrderService`) had **never once** reached Cloud Monitoring, going all the way back to
the very first deployment - two independent, stacked bugs, both found by reading actual source
rather than guessing:

1. `application.yml` configured Micrometer's OTLP metrics export under
   `management.metrics.export.otlp.*`. Confirmed directly against Spring Boot 3.2.4's own
   `OtlpProperties.java`: the real prefix is `management.otlp.metrics.export.*` (metrics/export and
   otlp are in the opposite order). Spring's relaxed binding doesn't error on unrecognized nested
   keys, so this was silently ignored the entire time, and Micrometer kept using
   `OtlpProperties`'s hardcoded default (`http://localhost:4318/v1/metrics`, unreachable in this
   pod) - confirmed via live logs: `java.net.ConnectException: Connection refused`, every ~60s,
   since the first deployment. (`naming.convention` and `properties.otel.service.name`, also under
   the wrong prefix, don't correspond to any field on `OtlpProperties` at all - removed rather than
   left as dead config once the block was rewritten.) This is a completely separate config path
   from the OTel Java agent's `OTEL_EXPORTER_OTLP_ENDPOINT` env var, which only the agent's own
   auto-instrumentation reads - the `jvm_*`/`http_server_requests_*`/etc. metrics that *did* appear
   in Cloud Monitoring the whole time turned out to be attributed to `service_name: camunda-operate`
   (Operate is also a Spring Boot app internally, scraped via Prometheus), not our app at all - a
   false positive that delayed catching this.
2. Fixing #1 traded `Connection refused` for `HTTP 404` from the collector itself. Root cause in
   `otel-collector.yaml`: the `metrics` pipeline listed `receivers: [prometheus]` only - the `otlp`
   receiver was wired into the `traces` pipeline but never the `metrics` one, so the collector had
   no route for OTLP-sourced metrics and didn't even bind `/v1/metrics` for that purpose. This is
   also why traces already worked (n8n's, confirmed visible in Cloud Trace earlier) while OTLP
   metrics never had anywhere to go. Fixed by adding `otlp` to the metrics pipeline's receivers
   alongside the existing `prometheus` one.

Diagnostic approach worth noting: `/actuator/metrics` (a core actuator endpoint, no extra
dependency) confirmed the counters were correctly registered and incrementing *locally*
(`orders.created` 0 -> 1 after a real order) before either fix, which ruled out `OrderService`
itself and correctly pointed at the export path as the only remaining suspect.

Verified live after both fixes: `workload.googleapis.com/orders.created` and
`workload.googleapis.com/orders.failed` now exist as real metric descriptors in Cloud Monitoring.

**Affected Components**:
- `spring-boot-app/src/main/java/com/helloobservability/OrderService.java`
- `spring-boot-app/src/main/resources/workflows/order-process.bpmn`
- `spring-boot-app/src/main/resources/application.yml`
- `spring-boot-app/build.gradle.kts`
- `helm-values/camunda-values.yaml`
- `k8s-infrastructure/elasticsearch-computeclass.yaml`
- `k8s-infrastructure/otel-collector.yaml`
- `n8n/order-validation.json`
- `scripts/n8n-import-workflow.js`
- `scripts/up.sh`

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
