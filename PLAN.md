# PLAN.md - Observability Learning Journey

## Goal
Learn Observability (traces, metrics, logs) with Camunda, n8n, and Google Cloud by building a fake business process with SLI/SLO monitoring - built the way a production system would be, since this PoC directly informs how the real project gets set up.

## Architecture
```
Spring Boot (Order API)
    → Camunda 8 (BPMN Workflow)
        → Camunda Connectors runtime (io.camunda:http-json:1)
            → n8n (Validation Webhook)
    → Google Cloud (Trace, Monitoring, Logging)
    ← Camunda Operate (Workflow UI)
```

## Golden Signals SLI/SLO

| Signal | SLI | SLO | Source |
|---|---|---|---|
| **Latency** | 95th percentile end-to-end time | < 2s | Spring Boot `orders.latency` (Micrometer) |
| **Throughput** | Orders processed/minute | > 10/min | Spring Boot `orders.created` (Micrometer) |
| **Errors** | Failed orders / total orders | < 1% | Spring Boot `orders.failed` (Micrometer) |
| **Saturation** | Active workflow instances | < 100 concurrent | Zeebe/Operate metrics (Prometheus scrape) |

## Technology Stack
- **Build**: Gradle (Kotlin DSL)
- **Java**: 21 (LTS)
- **Spring Boot**: 3.2.4
- **Camunda Client**: `io.camunda:camunda-client-java:8.8.0` + `io.camunda:camunda-spring-boot-starter:8.8.0`
  (the starter is what actually turns `application.yml`'s `camunda.client.*` properties into a
  usable `CamundaClient` bean - it's referenced by config today but not yet a dependency)
- **Camunda Server**: Helm chart `camunda-platform` 11.12.3 (Camunda 8.6.x)
- **Workflow integration pattern**: Camunda Connectors (`io.camunda:http-json:1`) for the
  Zeebe → n8n call, not a hand-rolled job worker - see "Why Connectors" below
- **OTel**: Java Agent (automatic instrumentation) + Micrometer (custom business metrics)

### Why Connectors instead of a custom job worker
Camunda ships the HTTP JSON Connector specifically to eliminate hand-rolled job-worker code for
simple outbound HTTP calls - it's the pattern Camunda's own docs and product design point at for
this exact case (see [outbound connectors](https://docs.camunda.io/docs/components/connectors/use-connectors/outbound/)).
It gets you built-in retries (`zeebe:taskDefinition retries="N"`, with optional backoff), a
FEEL `resultExpression` for mapping the HTTP response into process variables, and the connector
call shows up as its own step in Operate - all without writing/maintaining Java code for the
HTTP call itself. A job worker is still the right tool when the integration needs real business
logic, non-HTTP protocols, or tighter code-level testability; this PoC's n8n call is neither, so
Connectors is the more production-representative choice.

## Known issues found in review (2026-07-30)
Full root-cause writeups are in `ISSUE.md`. Short version: the project's checklist below had a lot
of "artifact exists" items checked that were never actually wired end-to-end. Specifically:
- `scripts/up.sh` had timeout/parallelism problems - **fixed**, see `ISSUE.md` #1 addendum.
- Wrong namespace/port in three places (Zeebe gateway address in `application.yml`, Camunda
  Operate's Prometheus scrape target, Spring Boot's own scrape target) - **fixed**.
- `order-process.bpmn` uses invented, non-existent Zeebe BPMN attributes and has structurally
  invalid error-handling XML - it would fail Zeebe's deployment validation as-is. **Not yet fixed**
  - see Phase 2 below.
- `OrderService.processOrder()` never calls Camunda at all (`Thread.sleep(100)` and return) - the
  Spring Boot → Camunda leg of the architecture has no code behind it yet. **Not yet fixed** - see
  Phase 2 below.
- Camunda Connectors runtime is disabled in `helm-values/camunda-values.yaml` - needed either way
  once Phase 2 lands. **Not yet fixed**.

## Step-by-Step Implementation Plan

### Phase 0: Infrastructure & Deployment Correctness
- [x] Rearchitect `scripts/up.sh` to run independent steps in parallel instead of one long
      sequential chain (cert-manager/OTel chain, n8n, Camunda, Spring Boot image build+deploy)
- [x] Add `readinessProbe`s to n8n and Spring Boot Deployments so `kubectl rollout status` is a
      real readiness gate (previously the script tried to curl pod IPs directly from the local
      machine, which GKE Autopilot doesn't route - this was the actual cause of the "timeouts")
- [x] Restore sane timeouts (a prior fix attempt had cut them in half, which made real slow
      operations fail outright instead of addressing the sequential-time problem)
- [x] Fix Zeebe gateway address default in `application.yml` (was `camunda` namespace / port
      `26662`; actual is `apps` namespace / port `26500`)
- [x] Fix OTel Collector Prometheus scrape targets in `otel-collector.yaml` (Operate is a
      Deployment behind a ClusterIP Service, not a StatefulSet - drop the `-0` pod-DNS prefix and
      scrape its `management` port 9600; Spring Boot's own Service exposes port 80, not 8080)
- [x] Fix the Zeebe Gateway ad-hoc health-check port in `up.sh` (`26501` doesn't exist in this
      chart; the actual actuator/management port is `9600`)
- [ ] Fix the n8n webhook URL namespace in the BPMN file (folded into the Phase 2 rewrite below,
      since that file needs a structural rewrite regardless)
- [ ] Set explicit CPU requests on containers currently relying on GKE Autopilot's
      `autopilot-default-resources-mutator` - observed live during the first real `up.sh` run: n8n,
      Spring Boot, and all three cert-manager Deployments (cert-manager, cert-manager-webhook,
      cert-manager-cainjector) had their CPU request silently defaulted rather than declared.
      Relying on the mutator means what's actually scheduled/billed doesn't match what's written
      down anywhere - `n8n.yaml`/`hello-observability-app.yaml` are ours to edit directly; the
      cert-manager ones come from the jetstack chart and need `--set` overrides (or a values file)
      added to `up.sh`'s `helm upgrade --install cert-manager` call

### Phase 1: Spring Boot App
- [x] Scaffold Spring Boot app in `spring-boot-app/`
- [x] Create Order API endpoint (POST /orders)
- [x] Add OpenTelemetry auto-instrumentation (Java Agent)
- [x] Add custom business metrics with Micrometer (order latency, throughput, errors)
- [x] Export metrics to OTel Collector
- [x] Add Dockerfile for containerization
- [x] Add k8s deployment YAML
- [x] Add unit tests for OrderService and OrderController
- [x] Add `io.camunda:camunda-spring-boot-starter:8.8.0` dependency (gives us an
      auto-configured client bean from `camunda.client.*` properties). Found two more bugs while
      verifying this locally with `./gradlew bootRun` (context failed to start until both were
      fixed - see `ISSUE.md` #2 addendum): `camunda.client.mode: simple` isn't a valid value at
      this client version (only `self-managed`/`saas` are), and `camunda.client.zeebe.gateway-address`
      isn't a recognized property or legacy alias at all - the current property is the flat
      `camunda.client.grpc-address`. Both fixed in `application.yml`; confirmed the app now boots
      cleanly (`Started HelloObservabilityApplication`) with a real `zeebeClient` bean created.
- [x] Wire `OrderService` to start a Camunda process instance per order (`orderId`/`itemName`/
      `quantity` as process variables) via the (deprecated-but-functional, see Phase 8)
      `ZeebeClient` bean; `orders.created`/`orders.failed` now reflect whether the process
      instance actually started, not just whether the HTTP request was received. Added
      `@Deployment(resources = "classpath*:/workflows/*.bpmn")` on the application class so the
      BPMN auto-deploys at startup. Verified locally (`./gradlew test` + `bootRun`), which
      surfaced two more real issues fixed along the way:
  - `camunda.client.rest-address` was never set, so BPMN auto-deployment (which goes over REST,
    not gRPC) silently defaulted to `http://localhost:8088` - fixed in `application.yml`.
  - `@Deployment`'s startup deploy call is synchronous and fatal with no retry: if Zeebe's REST
    gateway isn't reachable yet, the whole app crashes at startup (traced into
    `DeploymentAnnotationProcessor.start()` in the starter's source - confirmed, not guessed).
    Since Camunda can take minutes to become ready and deploys in parallel with this app, added an
    `initContainer` to `hello-observability-app.yaml` that blocks pod startup until the Zeebe
    Gateway's REST port is reachable, instead of relying on Kubernetes crash-loop-backoff to
    eventually succeed.

### Phase 2: Camunda Workflow (Connector-based)
- [x] Enable the Connectors runtime in `helm-values/camunda-values.yaml`
      (`connectors.enabled: true`); explicitly set `connectors.inbound.mode: disabled` since this
      PoC only needs outbound calls and identity/OAuth is disabled cluster-wide (verified with
      `helm template` against the actual chart - renders cleanly)
- [x] Rewrite `order-process.bpmn`:
  - [x] Give `ValidateOrder` a real `zeebe:taskDefinition type="io.camunda:http-json:1"`
        (replaces the invented `zeebe:httpMethod`/`zeebe:httpUrl` attributes, which Zeebe
        silently drops, leaving the task with no job type and an unpassable deployment)
  - [x] Add the connector's real input mapping: `method`, `url` (fixed to the `apps` namespace -
        `http://n8n-service.apps.svc.cluster.local:5678/webhook/order-validation`), `headers`,
        `body` (FEEL context built from the process variables)
  - [x] Map the response via `resultVariable`/`resultExpression` (`zeebe:taskHeader`s); added
        `errorExpression` to turn an HTTP >= 400 response into a real BPMN error
        (`bpmnError(...)`), separate from n8n successfully responding `valid: false`, which is a
        normal business outcome, not an error
  - [x] Fix the malformed error-handling branch: a `bpmn:boundaryEvent` cannot be nested inside a
        `bpmn:intermediateCatchEvent` - moved to a real boundary event attached to `ValidateOrder`
        (`attachedToRef`), and defined the `ValidationServiceError` `bpmn:error` element it
        references (previously referenced but never defined)
  - [x] Added an exclusive gateway (`Gateway_OrderValid`) branching on `validationResult.valid` -
        the previous file had no actual valid/invalid branching, only the (broken) error path
  - Validated against `zeebe-bpmn-moddle` (the schema library Camunda's own tooling uses): parses
    clean with no warnings, `taskDefinition`/`errorRef`/gateway `default` all resolve correctly
- [x] Deploy the BPMN (auto-deploy via `@Deployment` on app startup) - passed Zeebe's deployment
      validation cleanly against the live cluster
- [x] Verify end-to-end against the live cluster: `POST /orders` returned 200; confirmed via an
      independent source (n8n's own execution log, not just Spring Boot's response) that the
      Connector genuinely called n8n with the real order data - execution history contains the
      exact `orderId` from the request. Operate's own API needs CSRF handling beyond a session
      cookie to query programmatically (not pursued - it's a visual tool, easy to check directly
      via `kubectl port-forward svc/camunda-poc-operate 8081:80 -n apps` then
      http://localhost:8081, demo/demo)

### Phase 3: Continuous Integration (GitHub Actions)
Everything checked off in Phase 2 was verified by hand tonight (`./gradlew test`, a `bootRun`
smoke test, `helm template` against the real chart, BPMN schema validation via `zeebe-bpmn-moddle`
in Node.js). None of that runs automatically today - the next person (or the next session) to
touch `order-process.bpmn` or `OrderService` has no safety net catching the same class of bugs
found this session (invalid BPMN, dead config properties, broken client wiring) before they reach
a live cluster. Worth doing now, before Phases 4-6 add more surface area to regress.
- [ ] Add a GitHub Actions workflow (`.github/workflows/ci.yml`) triggered on push/PR that runs:
  - [ ] `./gradlew test` in `spring-boot-app/` (OrderService/OrderController unit tests)
  - [ ] BPMN schema validation for `order-process.bpmn` against `zeebe-bpmn-moddle` - commit the
        Node.js validation script used ad hoc tonight into the repo (e.g.
        `scripts/validate-bpmn.mjs`) instead of leaving it as a throwaway script, so CI and local
        dev use the same check
  - [ ] `helm template` dry-run of `helm-values/camunda-values.yaml` against the pinned chart
        version (11.12.3) - this alone would have caught tonight's Connectors config mistakes
        without needing a live cluster
- [ ] Cache Gradle dependencies between runs (`actions/setup-java`'s built-in Gradle cache, or
      `actions/cache`) so CI stays fast
- [ ] Once CI is green reliably, consider branch protection requiring it to pass before merge to
      `main` - not urgent for a single-dev/AI workflow today, but cheap to add later if that changes

### Phase 4: n8n Workflow
- [x] Create webhook workflow for order validation
- [x] Deploy to n8n (automated in `up.sh`)
- [x] Fix the workflow import/activation automation and the workflow itself - the first real
      deployment surfaced four real, stacked bugs, all traceable to `n8n.yaml` pinning
      `docker.n8n.io/n8nio/n8n:latest` while the workflow JSON was authored against a much older
      n8n version (now running 2.32.6). None were findable without a live n8n instance - see
      `ISSUE.md` #2 addendum:
  - n8n now requires completing owner setup + session login before any API call succeeds at all
    (previously unauthenticated) - `scripts/n8n-import-workflow.js` handles this now
  - The Webhook node needed `responseMode: "lastNode"` + `responseData: "firstEntryJson"` - it was
    acknowledging requests immediately (`{"message":"Workflow was started"}`) instead of waiting
    for the workflow to finish and returning its actual output
  - The "Valid Order"/"Invalid Order" Set nodes were pinned to `typeVersion: 1`, which expects an
    entirely different parameter schema (`values.boolean`/`values.string`) than what the file
    actually provided (`assignments.assignments`, the V2/V3 schema) - so they silently passed
    input through unchanged. Bumped to `typeVersion: 3.4`, which matches the schema already in use
  - The "Check Quantity" IF node's condition read `$json.quantity`, but n8n's Webhook node nests
    the actual request payload under `.body` - so the condition always evaluated false regardless
    of the real quantity. Fixed to `$json.body.quantity`
  - Also removed a duplicate `parameters` key on both Set nodes (dead JSON - the second occurrence
    silently wins during parsing, so it wasn't the active bug, but it was confusing and untracked)
  - `up.sh`'s import step itself was also broken independent of all of the above: busybox wget (no
    curl/jq in this image) has no `--method` flag at all, so its `--method=PUT .../activate` call
    could never have worked even on an older n8n; and piping the workflow JSON through
    `echo '...' | wget --post-data=@-` across several layers of shell quoting corrupted the body.
    Replaced with `kubectl cp`-ing real files into the pod and running a committed Node script
    (`scripts/n8n-import-workflow.js`, using Node's built-in `fetch` - no method restrictions, no
    shell-quoting layers to fight)
  - Verified live end-to-end: `POST /webhook/order-validation` with `quantity: 2` returns
    `{"valid":true,"message":"Order validated successfully"}`; `quantity: 0` returns
    `{"valid":false,...}` - both branches correct
- [ ] Add configurable delay (simulated API call) - stretch goal, not blocking
- [ ] Add error injection for testing - stretch goal, not blocking

### Phase 5: Camunda Operate
- [x] Enable Camunda Operate in `helm-values/camunda-values.yaml`
- [x] Enable Elasticsearch as Operate's data backend. Discovered live during the first real
      deployment (not something static analysis could have caught): Operate's schema-migration
      init container fails outright with `Connection refused` when Elasticsearch is disabled -
      `operate.enabled: true` + `elasticsearch.enabled: false` is not a valid combination, Operate
      cannot start at all without it (see `ISSUE.md` #2 addendum). Sized down hard from the
      chart's 3-node default to a single node for a PoC (`master.replicaCount: 1`,
      `data.replicaCount: 0`, combined master+data role). GKE Autopilot forbids the
      privileged-initContainer trick charts normally use to set `vm.max_map_count`, so added
      `k8s-infrastructure/elasticsearch-computeclass.yaml` (a GKE `ComputeClass`, the
      Autopilot-native mechanism for node-level kernel settings) and disabled the chart's
      redundant/now-harmful `sysctlImage` init container, which runs `privileged: true` and would
      otherwise fail Autopilot admission outright. Verified via `helm template` (renders with no
      privileged containers) and `helm install --dry-run=server` (passes real admission-adjacent
      validation) before applying to the live cluster.
- [ ] Port-forward and verify workflow instances are visible (blocked on Phase 2)
- [ ] Use Operate to inspect trace context propagation through the Connector call (needs
      verification - it's not guaranteed the Connector Runtime propagates the Zeebe job's trace
      context onto the outbound HTTP call automatically; check the trace in Cloud Trace once
      Phase 2 is live before assuming it's continuous)

### Phase 6: OTel Metrics
- [x] Export custom metrics from Spring Boot
- [x] Export workflow metrics from Camunda (scrape target now fixed - needs live verification)
- [x] Export processing metrics from n8n
- [ ] Verify metrics actually flow to Google Cloud Monitoring (live verification once Phase 0/2
      are deployed and generating traffic)

### Phase 7: Google Cloud Dashboards
- [ ] Create dashboard with golden signals
- [ ] Add SLO burn rate alerts
- [ ] Correlate traces with metrics
- [ ] Add log correlation with trace IDs

### Phase 8: Upgrade to Camunda 8.10 (deferred - not blocking Phases 1-7)
The real project this PoC informs will run Camunda 8.10, not 8.8.0. `camunda-spring-boot-starter`
currently auto-configures the older `ZeebeClient` bean (deprecated, slated for removal in 8.10 -
see `ISSUE.md` #2 addendum), which is what Phase 1's `OrderService` wiring uses. That's the right
call for now: it's what the starter actually wires up by default at 8.8.0, and switching to the
newer `io.camunda.client.CamundaClient` bean wasn't confirmed to be a clean drop-in without further
investigation. Once 8.10 is out:
- [ ] Migrate `ZeebeClient` usage in `OrderService` to `io.camunda.client.CamundaClient`
- [ ] Bump the client dependency to 8.10.x - check the artifact name before assuming it's still
      `io.camunda:camunda-spring-boot-starter`. The `camunda/camunda` repo's main branch already
      shows a split into `camunda-spring-boot-3-starter` / `camunda-spring-boot-4-starter` (plus a
      deprecated alias for the old unversioned name), so this may have changed by the time 8.10
      ships.
- [ ] Bump `helm-values/camunda-values.yaml`'s chart/version pin (currently chart 11.12.3 /
      Camunda 8.6.x, deliberately chosen to avoid the unified-image/Elasticsearch
      `max_map_count` kernel issues that later versions hit on GKE Autopilot - re-verify whether
      8.10's deployment model still has that problem before bumping)
- [ ] Re-check the HTTP JSON connector element template for changes (used v17's property set when
      writing `order-process.bpmn`'s REST Connector task - Camunda connector templates do version)
- [ ] Re-run the same verification steps used for the 8.8.0 wiring before deploying: `helm
      template` against the real chart, `zeebe-bpmn-moddle` schema validation on the BPMN, and a
      local `./gradlew bootRun` smoke test - all three caught real bugs during the 8.8.0 work that
      would otherwise have only surfaced live on the cluster

### Phase 9: Local Docker Compose environment (future research, not scheduled)
Raised 2026-07-30: the workstation this project is developed on is well beyond what this PoC
needs (128GB RAM, 16-thread Ryzen 7 5800X3D, 12TB disk), which opens up local-only iteration as a
real alternative to a live GKE cluster for day-to-day development - zero GCP cost while iterating,
only spinning up the real cluster occasionally for cloud-specific validation (Cloud Trace/Monitoring
export, GKE Autopilot behavior itself).

This isn't just easier logistically - it sidesteps entire categories of problems this session hit
that are specific to GKE Autopilot and don't exist on plain Docker:
- No Autopilot admission restrictions - privileged containers (e.g. Elasticsearch's normal
  `vm.max_map_count` init container, disabled in Phase 5 because Autopilot rejects it) just work,
  no `ComputeClass` workaround needed.
- No cert-manager / OTel Operator machinery - both exist solely to manage the OTel Collector's
  lifecycle and TLS certs declaratively in Kubernetes; a local Collector just needs a static YAML
  config file.
- No per-pod Autopilot resource minimums or cold-start node-provisioning delays (this session's
  n8n/Spring Boot rollout-status timeouts were real GKE node-autoscaling lag, not app slowness).
- `vm.max_map_count` becomes a one-line `sudo sysctl -w vm.max_map_count=1048576` on the host
  instead of a GKE-specific `ComputeClass` detour, since Docker containers share the host kernel
  directly.

Confirmed (not assumed) that Camunda officially maintains a docker-compose distribution of the
full 8.x stack (Zeebe, Operate, Connectors, Elasticsearch) at
[`camunda/camunda-distributions`](https://github.com/camunda/camunda-distributions/tree/main/docker-compose),
explicitly intended for local dev use. Our pinned version (chart 11.12.3 / Camunda 8.6.x) predates
Camunda 8.10's later change to unbundle Elasticsearch from that distribution, so it should still
include everything we need.

What adapting it to this project would actually involve:
- [ ] Layer n8n, the Spring Boot app (existing `Dockerfile` already works), and a static OTel
      Collector config on top of Camunda's official compose file
- [ ] Swap the handful of Kubernetes-internal DNS names our code currently hardcodes
      (`n8n-service.apps.svc.cluster.local`, `camunda-poc-zeebe-gateway.apps.svc.cluster.local`,
      etc. - in `order-process.bpmn` and `application.yml`) for Docker Compose service names.
      `application.yml`'s Zeebe address is already env-var-overridable
      (`CAMUNDA_CLIENT_GRPC_ADDRESS`); the BPMN's n8n URL is currently a hardcoded literal and
      would need to become configurable too (e.g. a FEEL expression reading a process variable, or
      a separate local-dev copy of the BPMN)
- [ ] Sort out GCP credentials for telemetry export from outside GKE - no Workload Identity
      available locally, so the Collector would need a downloaded service account key file mounted
      in instead (or just skip GCP export for pure local dev and use a console/debug exporter,
      saving the cloud round-trip entirely for fast iteration)
- [ ] One-time host setup: `sudo sysctl -w vm.max_map_count=1048576` (or persist via
      `/etc/sysctl.conf`) so Elasticsearch's container can start without any Kubernetes-specific
      workaround

Estimated as bounded, well-understood work (roughly an hour or two) rather than a redesign, given
the official Camunda compose distribution already does the hard part.

## Environment
- GCP project: `hellootelworld`
- Region: `us-central1`
- Cluster: `hello-observability-cluster`
- Namespaces:
  - `observability`: OTel Collector
  - `apps`: n8n, Camunda 8, Spring Boot
