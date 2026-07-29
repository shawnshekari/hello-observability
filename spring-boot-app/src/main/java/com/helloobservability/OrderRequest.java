package com.helloobservability;

public record OrderRequest(String orderId, String itemName, int quantity) {
}
