FROM alpine:latest

ARG BUILD_DATE
ARG VCS_REF
ARG ARIANG_VERSION=1.3.10
ARG ARIA2_VERSION=1.37.0

# Create non-root user
RUN addgroup -S -g 1000 aria2 && \
    adduser -S -D -H -h /aria2 -s /sbin/nologin -G aria2 -u 1000 aria2

ENV ARIA2RPCPORT=8080 \
    PUID=1000 \
    PGID=1000

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
    tzdata && \
    rm -rf /var/cache/apk/* && \
    aria2c --version

# AriaNG
WORKDIR /usr/local/www/ariang

# Download and install AriaNg
RUN wget --no-check-certificate https://github.com/mayswind/AriaNg/releases/download/${ARIANG_VERSION}/AriaNg-${ARIANG_VERSION}.zip \
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
    chown -R aria2:aria2 /aria2 /usr/local/www/ariang

VOLUME /aria2/data
VOLUME /aria2/conf

EXPOSE 8080

USER aria2

ENTRYPOINT ["./start.sh"]
CMD ["--conf-path=/aria2/conf/aria2.conf"]