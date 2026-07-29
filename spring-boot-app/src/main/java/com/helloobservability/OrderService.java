package com.helloobservability;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Service;

@Service
public class OrderService {

    private final Counter ordersCreated;
    private final Counter ordersFailed;
    private final Timer orderLatency;

    public OrderService(MeterRegistry registry) {
        this.ordersCreated = registry.counter("orders.created");
        this.ordersFailed = registry.counter("orders.failed");
        this.orderLatency = Timer.builder("orders.latency")
                .description("Latency of order processing")
                .register(registry);
    }

    public OrderRequest processOrder(OrderRequest request) {
        ordersCreated.increment();
        Timer.Sample sample = Timer.start();
        try {
            // Simulate order processing
            Thread.sleep(100);
            return request;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            ordersFailed.increment();
            return request;
        } finally {
            sample.stop(orderLatency);
        }
    }
}
