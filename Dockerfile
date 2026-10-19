# syntax=docker/dockerfile:1

FROM debian:bookworm-slim AS installer-base

COPY --link --chmod=755 docker/install-1cv8.sh /usr/local/bin/install-1cv8.sh

# The installer is mounted rather than copied, so it does not end up in a layer.
FROM installer-base AS installer-server

ARG ONEC_VERSION
ARG ONEC_COMPONENTS=server,ws

RUN --mount=type=bind,source=distr,target=/tmp/distr,rw \
    ONEC_VERSION="${ONEC_VERSION}" ONEC_COMPONENTS="${ONEC_COMPONENTS}" \
    install-1cv8.sh /tmp/distr

FROM installer-base AS installer-full

ARG ONEC_VERSION
ARG ONEC_COMPONENTS=server,ws
ARG ONEC_CLIENT_COMPONENTS=client_thin

RUN --mount=type=bind,source=distr,target=/tmp/distr,rw \
    ONEC_VERSION="${ONEC_VERSION}" ONEC_COMPONENTS="${ONEC_COMPONENTS},${ONEC_CLIENT_COMPONENTS}" \
    install-1cv8.sh /tmp/distr

# Removes installers of the client application agent (shipped with client_full),
# wxWidgets builds for WebKitGTK 4.1 (the image has 4.0) and the C++ runtime some versions
# ship: it is older than the one of Debian 12, which WebKitGTK needs. The 1cestart launcher
# in common/ ships copies of the platform libraries: identical ones are replaced with links.
RUN rm -rf "/opt/1cv8/x86_64/${ONEC_VERSION}/ExtDst" \
        "/opt/1cv8/x86_64/${ONEC_VERSION}"/*.wk41 \
        "/opt/1cv8/x86_64/${ONEC_VERSION}"/libstdc++.so.6* \
        /opt/1cv8/common/*.wk41 \
        /opt/1cv8/common/libstdc++.so.6* \
    && for f in /opt/1cv8/common/*; do \
        platform_file="/opt/1cv8/x86_64/${ONEC_VERSION}/${f##*/}"; \
        if cmp -s "$f" "$platform_file"; then ln -sf "$platform_file" "$f"; fi; \
    done

# The noVNC web client with websockify, its WebSocket proxy to the VNC server, laid out
# the way novnc_proxy expects. Upstream releases are used because the Debian packages are
# older and depend on Node.js and numpy.
FROM debian:bookworm-slim AS novnc

ARG NOVNC_VERSION=1.7.0
ARG WEBSOCKIFY_VERSION=0.13.0

ADD https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz /tmp/novnc.tar.gz
ADD https://github.com/novnc/websockify/archive/refs/tags/v${WEBSOCKIFY_VERSION}.tar.gz /tmp/websockify.tar.gz

RUN mkdir -p /novnc/utils/websockify \
    && tar -xzf /tmp/novnc.tar.gz -C /novnc --strip-components=1 --wildcards \
        '*/app' '*/core' '*/vendor' '*/vnc.html' '*/defaults.json' '*/mandatory.json' \
        '*/package.json' '*/LICENSE.txt' '*/utils/novnc_proxy' \
    && cp /novnc/vnc.html /novnc/index.html \
    && echo '{"resize": "scale"}' >/novnc/defaults.json \
    && tar -xzf /tmp/websockify.tar.gz -C /novnc/utils/websockify --strip-components=1 \
        "websockify-${WEBSOCKIFY_VERSION}/run" "websockify-${WEBSOCKIFY_VERSION}/websockify" \
        "websockify-${WEBSOCKIFY_VERSION}/COPYING"

# Enchant 1, which older clients, such as those of 8.3.22, link against. Debian 12 has only
# Enchant 2, so the package comes from the Debian 10 archive.
FROM scratch AS enchant

ADD --checksum=sha256:42916be9a85eb409e210d2bfc58cd48a07968a7e303ad4b7d9f462aec4a2dc7c \
    https://archive.debian.org/debian/pool/main/e/enchant/libenchant1c2a_1.6.0-11.1+b1_amd64.deb /

# Everything the images share, without the platform
FROM debian:bookworm-slim AS runtime

ARG ONEC_VERSION
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.version="${ONEC_VERSION}"

# TZ: the server returns its local time, and containers default to UTC.
# HOME: Docker sets it to / for a user given with --user that has no entry in /etc/passwd.
ENV LANG=ru_RU.UTF-8 \
    LC_ALL=ru_RU.UTF-8 \
    TZ=Europe/Moscow \
    HOME=/home/usr1cv8 \
    ONEC_VERSION=${ONEC_VERSION} \
    ONEC_HOME=/opt/1cv8/current \
    ONEC_SRV_DATA=/home/usr1cv8/.1cv8/1C/1cv8

# After the system directories, so the platform binaries never shadow system commands
ENV PATH=${PATH}:${ONEC_HOME}

RUN sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources \
    && echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' \
        | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        fontconfig \
        fonts-liberation \
        libfontconfig1 \
        libfreetype6 \
        libglib2.0-0 \
        libgsf-1-114 \
        libgssapi-krb5-2 \
        libkrb5-3 \
        libnss-wrapper \
        locales \
        procps \
        tini \
        ttf-mscorefonts-installer \
        tzdata \
    && localedef -i ru_RU -f UTF-8 ru_RU.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 999 grp1cv8 \
    && useradd --system --uid 999 --gid grp1cv8 \
        --create-home --home-dir /home/usr1cv8 --shell /bin/bash usr1cv8

# The link points to the platform copied in by the next stages. The home directories are
# writable by everyone, so the platform also runs as an arbitrary user given with --user.
RUN mkdir -p /opt/1cv8 \
    && ln -s "/opt/1cv8/x86_64/${ONEC_VERSION}" "${ONEC_HOME}" \
    && mkdir -p "${ONEC_SRV_DATA}" /var/log/1C /var/1C/licenses \
    && chown -R usr1cv8:grp1cv8 /home/usr1cv8 /var/log/1C /var/1C \
    && find /home/usr1cv8 -type d -exec chmod 1777 {} +

COPY --link --chmod=755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --link docker/ibsrv.yml /usr/local/etc/ibsrv.yml
COPY --link --chmod=755 docker/healthcheck.sh /usr/local/bin/healthcheck.sh

USER 999:999
WORKDIR /home/usr1cv8

# Server data with the settings of the platform
VOLUME ["/home/usr1cv8/.1cv8"]

# 1540 - agent (ragent), 1541 - cluster manager (rmngr),
# 1545 - administration server (ras), 1550 - debug server (dbgs, with ONEC_DEBUG=true),
# 1560-1591 - worker processes (rphost), 8314 - standalone server (ibsrv)
EXPOSE 1540 1541 1545 1550 1560-1591 8314

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["ragent"]

# Checked every second while starting, so the container turns healthy as soon as the server is ready
HEALTHCHECK --interval=10s --timeout=5s --start-period=1m --start-interval=1s --retries=6 \
    CMD ["healthcheck.sh"]

FROM runtime AS server

LABEL org.opencontainers.image.title="1C:Enterprise 8.3 server"

COPY --link --from=installer-server /opt/1cv8 /opt/1cv8

FROM runtime AS full

ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="1C:Enterprise 8.3 server and clients"

# The 1cestart launcher and novnc_proxy
ENV PATH=${PATH}:/opt/1cv8/common:/usr/share/novnc/utils

# The virtual display the entrypoint starts next to the server: the clients run on it
# unless given another one, such as by xvfb-run
ENV DISPLAY=:99

USER 0

# GTK, WebKitGTK, GLU and Enchant 1 with a Russian dictionary for the clients, Xvfb with
# xvfb-run (needs xauth) for the virtual display, Fluxbox to switch between and move
# the windows on the display the entrypoint starts, x11vnc to watch it from the host,
# Python for websockify, which lets noVNC do that in a browser, x11-utils (xwininfo,
# xdpyinfo) to inspect windows, ImageMagick (import) for screenshots and ping, which
# Vanessa Automation calls on Linux to pause
RUN --mount=type=bind,from=enchant,target=/tmp/enchant \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        fluxbox \
        hunspell-ru \
        imagemagick \
        iputils-ping \
        libglu1-mesa \
        libgtk-3-0 \
        libwebkit2gtk-4.0-37 \
        python3 \
        x11-utils \
        x11vnc \
        xauth \
        xvfb \
        /tmp/enchant/libenchant1c2a_1.6.0-11.1+b1_amd64.deb \
    && rm -rf /var/lib/apt/lists/*

USER 999:999

# Without a hardware license key the clients search for it and then ask a modal
# question whether to stop using it, which blocks unattended runs
RUN mkdir -p /home/usr1cv8/.1C/1cestart \
    && chmod 1777 /home/usr1cv8/.1C /home/usr1cv8/.1C/1cestart \
    && echo UseHwLicenses=0 >/home/usr1cv8/.1C/1cestart/1cestart.cfg

# The default Fluxbox style sets a wallpaper, and with no suitable program for that
# in the image it shows an error window on every start
RUN mkdir -p /home/usr1cv8/.fluxbox \
    && chmod 1777 /home/usr1cv8/.fluxbox \
    && echo 'background: none' >/home/usr1cv8/.fluxbox/overlay

COPY --link --from=novnc /novnc /usr/share/novnc
COPY --link --from=installer-full /opt/1cv8 /opt/1cv8

# 5900 - VNC server (x11vnc), 6080 - noVNC
EXPOSE 5900 6080

# The server is the default target
FROM server
