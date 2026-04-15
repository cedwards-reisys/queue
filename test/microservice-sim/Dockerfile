FROM eclipse-temurin:21-jdk AS build
WORKDIR /app
COPY build.gradle settings.gradle ./
COPY gradle ./gradle
COPY src ./src
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && GRADLE_VERSION=8.12 \
    && curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o gradle.zip \
    && unzip -q gradle.zip \
    && ./gradle-${GRADLE_VERSION}/bin/gradle bootJar --no-daemon \
    && rm -rf gradle.zip gradle-${GRADLE_VERSION}

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/microservice-sim.jar app.jar
EXPOSE 8082
ENTRYPOINT ["java", "-jar", "app.jar"]
