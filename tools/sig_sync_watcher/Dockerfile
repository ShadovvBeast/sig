FROM alpine:3.19 AS builder

# Install Zig
RUN apk add --no-cache curl xz
# Use latest master build matching our repo
ARG ZIG_VERSION=0.16.0-dev.3006+94355f192
RUN curl -L https://ziglang.org/builds/zig-x86_64-linux-${ZIG_VERSION}.tar.xz | tar -xJ -C /opt
ENV PATH="/opt/zig-x86_64-linux-${ZIG_VERSION}:$PATH"

WORKDIR /app
COPY main.zig .

# Build static binary
RUN zig build-exe main.zig -target x86_64-linux-musl -OReleaseSafe --name sig-sync-watcher

# Minimal runtime image
FROM scratch
COPY --from=builder /app/sig-sync-watcher /sig-sync-watcher
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sig-sync-watcher"]
