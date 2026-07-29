FROM eclipse-temurin:21-jdk-alpine AS build
COPY --chmod=+rx gradlew /home/app/gradlew
COPY gradle /home/app/gradle
COPY build.gradle.kts settings.gradle.kts gradle.properties /home/app/
COPY src /home/app/src
RUN cd /home/app && ./gradlew bootJar --no-daemon

FROM eclipse-temurin:21-jre-alpine
COPY --from=build /home/app/build/libs/*.jar /app.jar
ENTRYPOINT ["java", "-jar", "/app.jar"]
