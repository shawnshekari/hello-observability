# PLAN.md - Observability Learning Journey

## Goal
Learn Observability (traces, metrics, logs) with Camunda, n8n, and Google Cloud by building a fake business process with SLI/SLO monitoring.

## Architecture
```
Spring Boot (Order API)
    → Camunda 8 (BPMN Workflow)
        → n8n (Validation Webhook)
    → Google Cloud (Trace, Monitoring, Logging)
    ← Camunda Operate (Workflow UI)
```

## Golden Signals SLI/SLO

| Signal | SLI | SLO |
|---|---|---|
| **Latency** | 95th percentile end-to-end time | < 2s |
| **Throughput** | Orders processed/minute | > 10/min |
| **Errors** | Failed orders / total orders | < 1% |
| **Saturation** | Active workflow instances | < 100 concurrent |

## Technology Stack
- **Build**: Gradle (Kotlin DSL)
- **Java**: 21 (LTS)
- **Spring Boot**: 3.2+
- **Camunda Client**: zeebe-client-java (official Camunda 8 client)
- **OTel**: Java Agent (automatic instrumentation) + Micrometer (custom business metrics)

## Implementation Plan

### Phase 1: Spring Boot App
- [ ] Scaffold Spring Boot app in `spring-boot-app/`
- [ ] Create Order API endpoint (POST /orders)
- [ ] Add OpenTelemetry auto-instrumentation (Java Agent)
- [ ] Add custom business metrics with Micrometer (order latency, throughput, errors)
- [ ] Export metrics to OTel Collector

### Phase 2: Camunda Workflow
- [ ] Create BPMN workflow for order processing
- [ ] Add service task to call n8n webhook
- [ ] Add error handling and retry logic
- [ ] Deploy to Camunda 8

### Phase 3: n8n Workflow
- [ ] Create webhook workflow for order validation
- [ ] Add configurable delay (simulated API call)
- [ ] Add error injection for testing
- [ ] Deploy to n8n

### Phase 4: Camunda Operate
- [ ] Enable Camunda Operate in `helm-values/camunda-values.yaml`
- [ ] Port-forward and verify workflow instances are visible
- [ ] Use Operate to inspect trace context propagation

### Phase 5: OTel Metrics
- [ ] Export custom metrics from Spring Boot
- [ ] Export workflow metrics from Camunda
- [ ] Export processing metrics from n8n
- [ ] Verify metrics flow to Google Cloud Monitoring

### Phase 6: Google Cloud Dashboards
- [ ] Create dashboard with golden signals
- [ ] Add SLO burn rate alerts
- [ ] Correlate traces with metrics
- [ ] Add log correlation with trace IDs

## Environment
- GCP project: `hellootelworld`
- Region: `us-central1`
- Cluster: `hello-observability-cluster`
