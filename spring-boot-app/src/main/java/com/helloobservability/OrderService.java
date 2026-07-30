package com.helloobservability;

import io.camunda.zeebe.client.ZeebeClient;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Service;

import java.util.Map;

@Service
public class OrderService {

    private static final String PROCESS_ID = "order-process";

    private final ZeebeClient zeebeClient;
    private final Counter ordersCreated;
    private final Counter ordersFailed;
    private final Timer orderLatency;

    public OrderService(ZeebeClient zeebeClient, MeterRegistry registry) {
        this.zeebeClient = zeebeClient;
        this.ordersCreated = registry.counter("orders.created");
        this.ordersFailed = registry.counter("orders.failed");
        this.orderLatency = Timer.builder("orders.latency")
                .description("Latency of order processing")
                .register(registry);
    }

    public OrderRequest processOrder(OrderRequest request) {
        Timer.Sample sample = Timer.start();
        try {
            zeebeClient.newCreateInstanceCommand()
                    .bpmnProcessId(PROCESS_ID)
                    .latestVersion()
                    .variables(Map.of(
                            "orderId", request.orderId(),
                            "itemName", request.itemName(),
                            "quantity", request.quantity()))
                    .send()
                    .join();
            ordersCreated.increment();
            return request;
        } catch (RuntimeException e) {
            ordersFailed.increment();
            throw e;
        } finally {
            sample.stop(orderLatency);
        }
    }
}
