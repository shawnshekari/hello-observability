package com.helloobservability;

import io.camunda.client.annotation.Deployment;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
@Deployment(resources = "classpath*:/workflows/*.bpmn")
public class HelloObservabilityApplication {
    public static void main(String[] args) {
        SpringApplication.run(HelloObservabilityApplication.class, args);
    }
}
