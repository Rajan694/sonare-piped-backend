FROM eclipse-temurin:21-jdk AS build

WORKDIR /app/

COPY . /app/

RUN --mount=type=cache,target=/root/.gradle/caches/ \
 ./gradlew shadowJar

# VERSION is gitignored (upstream CI writes it), so a fresh checkout has none; Piped
# reports "unknown" then, the same as with no file.
RUN [ -s VERSION ] || echo unknown > VERSION

FROM eclipse-temurin:21-jre

RUN --mount=type=cache,target=/var/cache/apt/ \
 apt-get update && \
 apt-get install -y --no-install-recommends \
  curl \
  && \
 apt-get clean && \
 rm -rf /var/lib/apt/lists/*

WORKDIR /app/

COPY hotspot-entrypoint.sh docker-healthcheck.sh /

COPY --from=build /app/build/libs/piped-1.0-all.jar /app/piped.jar

COPY --from=build /app/VERSION .

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 CMD /docker-healthcheck.sh
ENTRYPOINT ["/hotspot-entrypoint.sh"]
