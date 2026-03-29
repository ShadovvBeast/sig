FROM alpine:3.19 AS builder

# Install Sig compiler from GitHub releases
RUN apk add --no-cache curl xz
ARG SIG_VERSION=latest
RUN DOWNLOAD_URL=$(curl -s https://api.github.com/repos/ShadovvBeast/sig/releases/${SIG_VERSION} \
    | grep -o '"browser_download_url": *"[^"]*x86_64-linux[^"]*\.tar\.xz"' \
    | head -1 | cut -d'"' -f4) && \
    curl -L "$DOWNLOAD_URL" | tar -xJ -C /opt && \
    ln -s /opt/sig-*/bin/sig /usr/local/bin/sig

WORKDIR /app

# Copy sig library and conflict resolver source
COPY lib/sig/ lib/sig/
COPY tools/sig_conflict_resolver/*.sig tools/sig_conflict_resolver/

# Build static binary
RUN sig build-exe tools/sig_conflict_resolver/main.sig \
    --mod sig::lib/sig/sig.zig \
    --deps sig \
    -target x86_64-linux-musl -OReleaseSafe \
    --name sig-conflict-resolver

# Minimal runtime image
FROM scratch
COPY --from=builder /app/sig-conflict-resolver /sig-conflict-resolver
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sig-conflict-resolver"]
