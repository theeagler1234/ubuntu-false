# Single-container build for hosts that deploy one Dockerfile (Railway/Railpack).
#
# docker-compose.yml runs two containers: the access-gate and the desktop.
# Hosted platforms usually run one container per service and only route one
# public port, so here the gate runs *inside* the Webtop image:
#
#   internet -> $PORT (access-gate) -> 127.0.0.1:3100 (Webtop nginx)
#
# Local development still uses docker-compose.yml + access-gate/Dockerfile.

FROM lscr.io/linuxserver/webtop:ubuntu-xfce

# Python + aiohttp (same pinned version as access-gate/Dockerfile) in a venv,
# so it can't clash with the desktop's system Python packages.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv \
 && python3 -m venv /opt/gate \
 && /opt/gate/bin/pip install --no-cache-dir aiohttp==3.10.10 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/*

COPY access-gate/gate.py /opt/gate/gate.py

# Picked up by the LinuxServer init and supervised/restarted by s6.
COPY deploy/custom-services.d/ /custom-services.d/
RUN chmod +x /custom-services.d/*

# Non-secret settings (match docker-compose.yml).
# The desktop is moved off 3000/3001 so the gate can take whatever public
# port the platform injects as $PORT without ever colliding with it.
ENV PUID=1000 \
    PGID=1000 \
    TZ=Etc/UTC \
    CUSTOM_USER=ubuntu \
    TITLE="Ubuntu Codespace Desktop" \
    CUSTOM_PORT=3100 \
    CUSTOM_HTTPS_PORT=3101 \
    START_DOCKER=false

# Set these as service variables on the platform - never in this file:
#   ACCESS_CODE  required; the gate refuses to start without it
#   PASSWORD     required; the desktop's own login password

# Public port = $PORT (injected by the platform, falls back to 3000).
EXPOSE 3000
