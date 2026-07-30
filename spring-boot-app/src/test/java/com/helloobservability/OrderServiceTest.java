package com.helloobservability;

import io.camunda.zeebe.client.ZeebeClient;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.concurrent.CompletionException;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.RETURNS_DEEP_STUBS;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class OrderServiceTest {

    private ZeebeClient zeebeClient;
    private OrderService orderService;
    private MeterRegistry registry;

    @BeforeEach
    void setUp() {
        registry = new SimpleMeterRegistry();
        zeebeClient = mock(ZeebeClient.class, RETURNS_DEEP_STUBS);
        orderService = new OrderService(zeebeClient, registry);
    }

    @Test
    void processOrder_shouldStartProcessInstanceAndRecordMetrics() {
        OrderRequest request = new OrderRequest("order-1", "Widget", 2);

        OrderRequest result = orderService.processOrder(request);

        assertThat(result).isEqualTo(request);
        assertThat(registry.find("orders.created").counter().count()).isEqualTo(1);
        assertThat(registry.find("orders.failed").counter().count()).isEqualTo(0);
        assertThat(registry.find("orders.latency").timer().mean(TimeUnit.MILLISECONDS)).isGreaterThanOrEqualTo(0);
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
    void processOrder_shouldRecordFailedOrderWhenZeebeThrows() {
        OrderRequest request = new OrderRequest("order-1", "Widget", 1);
        when(zeebeClient.newCreateInstanceCommand()
                .bpmnProcessId(org.mockito.ArgumentMatchers.anyString())
                .latestVersion()
                .variables(org.mockito.ArgumentMatchers.<java.util.Map<String, Object>>any())
                .send()
                .join())
                .thenThrow(new CompletionException(new RuntimeException("broker unreachable")));

        assertThatThrownBy(() -> orderService.processOrder(request))
                .isInstanceOf(CompletionException.class);

        assertThat(registry.find("orders.created").counter().count()).isEqualTo(0);
        assertThat(registry.find("orders.failed").counter().count()).isEqualTo(1);
    }
}
