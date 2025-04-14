FROM alpine:3.19

ARG BUILD_DATE
ARG VCS_REF
ARG ARIANG_VERSION=1.3.10

ENV ARIA2RPCPORT=6800 \
    UI_PORT=8080 \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC \
    RPC_SECRET="" \
    EMBED_RPC_SECRET="" \
    BASIC_AUTH_USERNAME="" \
    BASIC_AUTH_PASSWORD=""

# Create non-root user with specified PUID and PGID
RUN set -e && \
    addgroup -S -g ${PGID} aria2 || { echo "Failed to create group with GID ${PGID}"; exit 1; } && \
    adduser -S -D -H -h /aria2 -s /sbin/nologin -G aria2 -u ${PUID} aria2 || { echo "Failed to create user with UID ${PUID}"; exit 1; }

# Install dependencies
RUN apk update && \
    apk add --no-cache --update \
    caddy \
    aria2 \
    su-exec \
    curl \
    xmlstarlet \
    bash \
    openssl \
    tzdata \
    netcat-openbsd && \
    rm -rf /var/cache/apk/* && \
    aria2c --version

# Create required directories
RUN mkdir -p /usr/local/caddy /var/log/caddy /aria2/conf-copy /aria2/conf /aria2/data

# AriaNG
WORKDIR /usr/local/www/ariang

# Download and install AriaNg
RUN wget --no-check-certificate --tries=3 --timeout=15 --retry-connrefused \
    https://github.com/mayswind/AriaNg/releases/download/${ARIANG_VERSION}/AriaNg-${ARIANG_VERSION}.zip \
    -O ariang.zip \
    && unzip ariang.zip \
    && rm ariang.zip \
    && chmod -R 755 ./

WORKDIR /aria2

COPY aria2.conf ./conf-copy/aria2.conf
COPY start.sh ./
COPY Caddyfile /usr/local/caddy/

# Set permissions
RUN chmod +x start.sh && \
    chown -R aria2:aria2 /aria2 /usr/local/www/ariang /var/log/caddy

VOLUME /aria2/data
VOLUME /aria2/conf
VOLUME /var/log/caddy

EXPOSE ${UI_PORT}
EXPOSE ${ARIA2RPCPORT}

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD pgrep caddy && [ -f /aria2/conf/aria2.pid ] && \
      kill -0 $(cat /aria2/conf/aria2.pid) 2>/dev/null && \
      curl -sf http://localhost:${UI_PORT} >/dev/null

ENTRYPOINT ["./start.sh"]
CMD ["--conf-path=/aria2/conf/aria2.conf"]