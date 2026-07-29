package com.helloobservability;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

class OrderServiceTest {

    private OrderService orderService;
    private MeterRegistry registry;

    @BeforeEach
    void setUp() {
        registry = new SimpleMeterRegistry();
        orderService = new OrderService(registry);
    }

    @Test
    void processOrder_shouldReturnOrderAndRecordMetrics() {
        OrderRequest request = new OrderRequest("order-1", "Widget", 2);

        OrderRequest result = orderService.processOrder(request);

        assertThat(result).isEqualTo(request);
        assertThat(registry.find("orders.created").counter().count()).isEqualTo(1);
        assertThat(registry.find("orders.latency").timer().mean(TimeUnit.MILLISECONDS)).isGreaterThan(0);
    }

    @Test
    void processOrder_shouldIncrementCounterForEachOrder() {
        OrderRequest request1 = new OrderRequest("order-1", "Widget", 1);
        OrderRequest request2 = new OrderRequest("order-2", "Gadget", 3);

        orderService.processOrder(request1);
        orderService.processOrder(request2);

        assertThat(registry.find("orders.created").counter().count()).isEqualTo(2);
    }

    @Test
    void processOrder_shouldRecordFailedOrderWhenInterrupted() {
        OrderRequest request = new OrderRequest("order-1", "Widget", 1);

        OrderService spyService = org.mockito.Mockito.spy(orderService);
        org.mockito.Mockito.doAnswer(invocation -> {
            Thread.currentThread().interrupt();
            return request;
        }).when(spyService).processOrder(request);

        spyService.processOrder(request);

        assertThat(registry.find("orders.failed").counter().count()).isEqualTo(1);
    }
}
