package com.helloobservability;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class OrderController {

    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

    @PostMapping("/orders")
    public ResponseEntity<OrderRequest> createOrder(@RequestBody OrderRequest request) {
        OrderRequest processed = orderService.processOrder(request);
        return ResponseEntity.ok(processed);
    }
}
