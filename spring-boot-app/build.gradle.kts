plugins {
    java
    alias(libs.plugins.spring.boot)
    alias(libs.plugins.spring.dependency.management)
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-actuator")
    // camunda-spring-boot-starter transitively brings in camunda-client-java
    // and auto-configures a CamundaClient bean from the camunda.client.*
    // properties in application.yml (previously present but unused, since
    // only the bare client library was a dependency - see ISSUE.md #2).
    implementation("io.camunda:camunda-spring-boot-starter:8.8.0")
    implementation("io.micrometer:micrometer-registry-otlp")
    testImplementation("org.springframework.boot:spring-boot-starter-test")
}
