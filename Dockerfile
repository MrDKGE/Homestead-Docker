# Homestead Minecraft Server - Dockerfile
# Base image with Java 17 (required for Minecraft 1.20.1 with Fabric)
FROM eclipse-temurin:17-jdk-jammy

# Metadata
LABEL org.opencontainers.image.title="Homestead Minecraft Server" \
      org.opencontainers.image.description="Dockerized Homestead modpack server with automatic version management" \
      org.opencontainers.image.authors="homestead-docker" \
      org.opencontainers.image.source="https://github.com/CozyCord/homestead" \
      minecraft.version="1.20.1" \
      modpack="homestead"

# Install required utilities in a single layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        wget \
        unzip \
        zip \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Set working directory
WORKDIR /server

# Create necessary directories
RUN mkdir -p /server /serverpack

# Copy entrypoint script
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Expose ports
EXPOSE 25565/tcp
EXPOSE 24454/udp

# Set default environment variables
ENV MEMORY="6G" \
    JAVA_ARGS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1" \
    ADDITIONAL_ARGS="-Dlog4j2.formatMsgNoLookups=true -Dusing.aikars.flags=https://mcflags.emc.gs" \
    EULA="false" \
    FABRIC_INSTALLER_VERSION="1.1.1" \
    MINECRAFT_VERSION="1.20.1" \
    MODLOADER_VERSION="0.17.2"

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5m --retries=3 \
    CMD pgrep -f "fabric-server-launch.jar" > /dev/null || exit 1

# Volumes
VOLUME ["/server", "/serverpack"]

# Use entrypoint script
ENTRYPOINT ["/entrypoint.sh"]
