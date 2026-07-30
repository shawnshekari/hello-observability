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

### Phase 1: Spring Boot App
- [x] Scaffold Spring Boot app in `spring-boot-app/`
- [x] Create Order API endpoint (POST /orders)
- [x] Add OpenTelemetry auto-instrumentation (Java Agent)
- [x] Add custom business metrics with Micrometer (order latency, throughput, errors)
- [x] Export metrics to OTel Collector
- [x] Add Dockerfile for containerization
- [x] Add k8s deployment YAML
- [x] Add unit tests for OrderService and OrderController
- [ ] Add `io.camunda:camunda-spring-boot-starter:8.8.0` dependency (gives us an
      auto-configured `CamundaClient` bean from the existing `camunda.client.*` properties)
- [ ] Wire `OrderService`/`OrderController` to actually start a Camunda process instance per
      order (`orderId`/`itemName`/`quantity` as process variables) - today it's a stub that just
      sleeps and returns

### Phase 2: Camunda Workflow (Connector-based)
- [ ] Enable the Connectors runtime in `helm-values/camunda-values.yaml`
      (`connectors.enabled: true`); explicitly set `connectors.inbound.mode: disabled` since this
      PoC only needs outbound calls and identity/OAuth is disabled cluster-wide
- [ ] Rewrite `order-process.bpmn`:
  - [ ] Give `ValidateOrder` a real `zeebe:taskDefinition type="io.camunda:http-json:1"`
        (replaces the invented `zeebe:httpMethod`/`zeebe:httpUrl` attributes, which Zeebe
        silently drops, leaving the task with no job type and an unpassable deployment)
  - [ ] Add the connector's real input mapping: `method`, `url` (fixed to the `apps` namespace -
        `http://n8n-service.apps.svc.cluster.local:5678/webhook/order-validation`), `headers`,
        `body` (FEEL context built from the process variables)
  - [ ] Map the response via `resultVariable`/`resultExpression` (`zeebe:taskHeader`s)
  - [ ] Fix the malformed error-handling branch: a `bpmn:boundaryEvent` cannot be nested inside a
        `bpmn:intermediateCatchEvent` - move it to a real boundary event attached to
        `ValidateOrder`, and define the `ValidationError` `bpmn:error` element it references
        (currently referenced but never defined)
- [ ] Deploy the BPMN (auto-deploy via the Spring starter's classpath resource deployment, or a
      manual deploy step) and confirm it passes Zeebe's deployment validation
- [ ] Verify end-to-end: `POST /orders` → process instance created → Connector calls n8n →
      instance completes → visible in Operate

### Phase 3: n8n Workflow
- [x] Create webhook workflow for order validation
- [x] Deploy to n8n (automated in `up.sh`)
- [ ] Add configurable delay (simulated API call) - stretch goal, not blocking
- [ ] Add error injection for testing - stretch goal, not blocking

### Phase 4: Camunda Operate
- [x] Enable Camunda Operate in `helm-values/camunda-values.yaml`
- [ ] Port-forward and verify workflow instances are visible (blocked on Phase 2)
- [ ] Use Operate to inspect trace context propagation through the Connector call (needs
      verification - it's not guaranteed the Connector Runtime propagates the Zeebe job's trace
      context onto the outbound HTTP call automatically; check the trace in Cloud Trace once
      Phase 2 is live before assuming it's continuous)

### Phase 5: OTel Metrics
- [x] Export custom metrics from Spring Boot
- [x] Export workflow metrics from Camunda (scrape target now fixed - needs live verification)
- [x] Export processing metrics from n8n
- [ ] Verify metrics actually flow to Google Cloud Monitoring (live verification once Phase 0/2
      are deployed and generating traffic)

### Phase 6: Google Cloud Dashboards
- [ ] Create dashboard with golden signals
- [ ] Add SLO burn rate alerts
- [ ] Correlate traces with metrics
- [ ] Add log correlation with trace IDs

## Environment
- GCP project: `hellootelworld`
- Region: `us-central1`
- Cluster: `hello-observability-cluster`
- Namespaces:
  - `observability`: OTel Collector
  - `apps`: n8n, Camunda 8, Spring Boot
