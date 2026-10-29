# syntax=docker/dockerfile:1

ARG PUREFTPD_VERSION=1.0.52
ARG DEBIAN_VERSION=bookworm

FROM debian:${DEBIAN_VERSION}-slim AS builder

ARG PUREFTPD_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    git \
    libssl-dev \
    libmariadb-dev \
    libpq-dev \
    libldap2-dev \
    libsodium-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch ${PUREFTPD_VERSION} https://github.com/jedisct1/pure-ftpd.git .

# ALWAYS_SHOW_RESOLVED_SYMLINKS lists symlinks to files and folders as what
# they point to, which -b (--brokenclientscompat) used to do. -b also refuses
# EPSV over IPv4 while FEAT still advertises it, which breaks clients such as
# n8n's FTP node, so the entrypoint no longer passes it.
RUN ./autogen.sh && CPPFLAGS="-DALWAYS_SHOW_RESOLVED_SYMLINKS" ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --without-humor \
    --without-inetd \
    --with-altlog \
    --with-cookie \
    --with-ftpwho \
    --with-ldap \
    --with-mysql \
    --with-pgsql \
    --with-puredb \
    --with-quotas \
    --with-ratios \
    --with-throttling \
    --with-tls \
    --with-uploadscript \
    --with-virtualchroot \
    --with-largefile \
    --with-peruserlimits \
    --with-diraliases \
    --with-certfile=/data/pureftpd.pem \
    && make -j$(nproc) \
    && make install DESTDIR=/build

FROM debian:${DEBIAN_VERSION}-slim

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    bash \
    openssl \
    libssl3 \
    libmariadb3 \
    libpq5 \
    libldap-2.5-0 \
    libsodium23 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/pure-ftpd/passwd \
    && mkdir -p /home/ftpusers \
    && mkdir -p /data

COPY --from=builder /build/usr /usr
ADD scripts /scripts
RUN chmod -R +x /scripts

# Sends POST /v1/apps/installed/${INSTANCE_ID} for the entrypoint. It retries
# network errors, 408, 429 and 5xx and stops on any other status.
COPY appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod 755 /usr/local/bin/appbox-installed-callback

# Create the entrypoint script
RUN cat > /entrypoint.sh <<'EOF'
#!/bin/bash
set -e

# Setup SSL certificate
mkdir -p /etc/ssl/private/
if [ -f /ssl/key.pem ] && [ -f /ssl/cert.pem ]; then
    cat /ssl/key.pem > /data/pureftpd.pem
    echo '' >> /data/pureftpd.pem
    cat /ssl/cert.pem >> /data/pureftpd.pem
    echo '' >> /data/pureftpd.pem
    chmod 600 /data/pureftpd.pem
fi

# Setup user if not configured
if [ ! -f /etc/app_configured ]; then
    if [ -n "$FTP_USER" ] && [ -n "$FTP_PASSWORD" ]; then
        pure-pw list 2>/dev/null | grep -q "$FTP_USER" || \
            (echo "$FTP_PASSWORD"; echo "$FTP_PASSWORD") | pure-pw useradd "$FTP_USER" -f /etc/pure-ftpd/passwd/pureftpd.passwd -m -d /home/ftpusers/default -u 1000 -g 1000
    fi
    if [ ! -f /etc/pure-ftpd/pureftpd.pdb ] && [ -f /etc/pure-ftpd/passwd/pureftpd.passwd ]; then
        pure-pw mkdb /etc/pure-ftpd/pureftpd.pdb -f /etc/pure-ftpd/passwd/pureftpd.passwd
    fi
    # Mark the installed callback pending if INSTANCE_ID is set, before the
    # configured marker so a crash in between cannot lose it. It is sent in
    # the background below.
    if [ -n "$INSTANCE_ID" ]; then
        touch /etc/appbox_callback_pending
    fi
    touch /etc/app_configured
fi

# Send a pending installed callback in the background. The helper stops on a
# rejection (e.g. 401 once the token was used or cleared) instead of retrying
# forever, and pure-ftpd starts whatever the API answers.
if [ -f /etc/appbox_callback_pending ]; then
    (
        set +e
        /usr/local/bin/appbox-installed-callback
        rm -f /etc/appbox_callback_pending
    ) </dev/null &
fi

# Build command line arguments
FTPD_ARGS="-l puredb:/etc/pure-ftpd/pureftpd.pdb"
[ -n "$PUBLICHOST" ] && FTPD_ARGS="$FTPD_ARGS -P $PUBLICHOST"
[ -n "$FIRST_PORT" ] && [ -n "$LAST_PORT" ] && FTPD_ARGS="$FTPD_ARGS -p $FIRST_PORT:$LAST_PORT"
FTPD_ARGS="$FTPD_ARGS -s -A -j -Z -H -4 -E -w -D -L 200000:5 -d -c 50 -C 50"

# Add TLS if certificate exists
if [ -f /data/pureftpd.pem ]; then
    FTPD_ARGS="$FTPD_ARGS --tls 1 --certfile=/data/pureftpd.pem"
fi

# Start pure-ftpd in foreground
exec pure-ftpd $FTPD_ARGS
EOF
RUN chmod +x /entrypoint.sh

EXPOSE 21
WORKDIR /data
VOLUME [ "/data" ]

ENTRYPOINT ["/entrypoint.sh"]
