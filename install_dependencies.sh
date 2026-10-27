#!/usr/bin/env bash
# Checks for Docker (with the compose plugin) and cloudflared, and installs
# whichever are missing. Supports Debian/Ubuntu, Fedora/RHEL and similar
# distros on x86_64 and arm64. Run it as a normal user; it uses sudo.
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  have sudo || { echo "This script needs root or sudo." >&2; exit 1; }
  SUDO="sudo"
fi

# Pick a downloader: wget first, then curl.
download() { # download <url> <output-file>
  if have wget; then
    wget -q --show-progress -O "$2" "$1"
  elif have curl; then
    curl -fL --progress-bar -o "$2" "$1"
  else
    echo "Neither wget nor curl is installed. Install one and re-run." >&2
    exit 1
  fi
}

case "$(uname -m)" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported CPU architecture: $(uname -m)" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== Checking dependencies =="

# --- Docker Engine + compose plugin -----------------------------------------
if have docker && docker compose version >/dev/null 2>&1; then
  echo "[ok] docker and docker compose are installed"
else
  echo "[missing] docker or the docker compose plugin - installing with Docker's official script"
  download https://get.docker.com "$TMP/get-docker.sh"
  $SUDO sh "$TMP/get-docker.sh"
  $SUDO systemctl enable --now docker 2>/dev/null || true
  TARGET_USER="${SUDO_USER:-$(id -un)}"
  if [ "$TARGET_USER" != "root" ]; then
    $SUDO usermod -aG docker "$TARGET_USER" || true
    echo "Added $TARGET_USER to the docker group. Log out and back in for this to take effect."
  fi
fi

# --- cloudflared --------------------------------------------------------------
if have cloudflared; then
  echo "[ok] cloudflared is installed"
else
  echo "[missing] cloudflared - downloading from the official GitHub releases"
  BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"
  if have apt-get; then
    download "$BASE/cloudflared-linux-$ARCH.deb" "$TMP/cloudflared.deb"
    $SUDO apt-get install -y "$TMP/cloudflared.deb"
  elif have dnf || have yum; then
    case "$ARCH" in amd64) RPMARCH="x86_64" ;; arm64) RPMARCH="aarch64" ;; esac
    download "$BASE/cloudflared-linux-$RPMARCH.rpm" "$TMP/cloudflared.rpm"
    if have dnf; then $SUDO dnf install -y "$TMP/cloudflared.rpm"; else $SUDO yum install -y "$TMP/cloudflared.rpm"; fi
  else
    # Fallback: plain binary
    download "$BASE/cloudflared-linux-$ARCH" "$TMP/cloudflared"
    $SUDO install -m 0755 "$TMP/cloudflared" /usr/local/bin/cloudflared
  fi
fi

echo
echo "== Final check =="
docker --version || echo "docker: not found (a re-login or reboot may be needed)"
docker compose version || echo "docker compose: not found"
cloudflared --version || echo "cloudflared: not found"

cat <<'EOF'

== Next: set up the Cloudflare tunnel ==
You need a free Cloudflare account and a domain managed by Cloudflare.

1. Set a strong password. go to docker-compose.yml:
find the line mentioning password and change it to something only YOU know,
DO NOT PUT IT AS 1234 OR KEEP IT AS change-this-password

2. Start the desktop:
     ./reopen-os.sh

3. Log in to Cloudflare (opens a browser link):
     cloudflared tunnel login

4. Create the tunnel:
     cloudflared tunnel create ubuntu-desktop

5. Point a hostname at it:
     cloudflared tunnel route dns ubuntu-desktop desktop.yourdomain.com

6. Create ~/.cloudflared/config.yml:
     tunnel: ubuntu-desktop
     credentials-file: /home/<you>/.cloudflared/<TUNNEL-ID>.json
     ingress:
       - hostname: desktop.yourdomain.com
         service: http://localhost:3000
       - service: http_status:404

7. Test it, then install it as a service so it starts on boot:
     cloudflared tunnel run ubuntu-desktop
     sudo cloudflared --config ~/.cloudflared/config.yml service install

8. Strongly recommended: in the Cloudflare Zero Trust dashboard, add an Access
   application for desktop.yourdomain.com so people must sign in by email code
   or Google before reaching the desktop login page.

For a quick throwaway test with no domain (URL changes every run):
     cloudflared tunnel --url http://localhost:3000
EOF
