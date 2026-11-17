#!/bin/bash
# install.sh — Variant P portal installer: nginx + Let's Encrypt + Xray VLESS+WS.
#
# What it builds (the deployment proven 2026-11-17 on a 2 vCPU / 1 GB
# Ubuntu 24.04 VPS in Singapore):
#   nginx owns 80+443 with a real Let's Encrypt certificate for <DOMAIN>
#   main Xray: VLESS + WebSocket on 127.0.0.1:10000, path /vless
#   clients reach it as wss://<DOMAIN>/vless (no open Xray port at all)
#   optional: one residential-exit country line per --countries entry
#   (see scripts/add-country.sh) behind /home-<name> on the same domain.
#
# Why WebSocket behind nginx, not Reality: on some networks (observed from
# Macau to this VPS) Reality/TLS handshakes to the VPS IP are interfered
# with and never complete, while plain WebSocket through nginx on 443 works.
# Reality remains available per country via templates/xray-home-reality.json
# if your network path supports it — see SKILL.md.
#
# Usage (run on a FRESH Ubuntu 22.04/24.04 VPS as root, from a repo checkout):
#   sudo ./install.sh --domain <YOUR_DOMAIN> --email <YOUR_EMAIL>
#   sudo ./install.sh --domain <YOUR_DOMAIN> --email <YOUR_EMAIL> --countries jp,kr
#   sudo ./install.sh --domain <YOUR_DOMAIN> --email <YOUR_EMAIL> --skip-homeline
#
# Prerequisites: the domain's A record must already point at this VPS
# (the installer checks); ports 80+443 must be open in the cloud security
# group AND the OS firewall. Idempotent: safe to re-run; it reuses the
# existing UUID and certificate instead of regenerating them.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="/opt/xray-portal-homeline"
BASE="${HOMELINE_BASE:-/opt/homeline}"
DOMAIN=""; EMAIL=""; COUNTRIES=""; SKIP_HOMELINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)       DOMAIN="$2"; shift 2;;
    --email)        EMAIL="$2"; shift 2;;
    --countries)    COUNTRIES="$2"; shift 2;;
    --skip-homeline) SKIP_HOMELINE=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$DOMAIN" ] && [ -n "$EMAIL" ] || {
  echo "usage: $0 --domain <YOUR_DOMAIN> --email <YOUR_EMAIL> [--countries jp,kr] [--skip-homeline]" >&2; exit 2; }
[ -f "$REPO_DIR/templates/xray-portal.json" ] || { echo "run from the repo root (templates/ missing)" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "=== 0. DNS check ==="
VPSIP="$(curl -s -m 10 https://api.ipify.org)"
echo "VPS public IP: $VPSIP"
RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
if ! printf '%s\n' "$RESOLVED" | grep -qx "$VPSIP"; then
  echo "ERROR: $DOMAIN does not resolve to this VPS ($VPSIP)." >&2
  echo "Point an A record for $DOMAIN at $VPSIP and wait for DNS, then re-run." >&2
  exit 1
fi
echo "DNS OK: $DOMAIN -> $VPSIP"

echo "=== 1. Base packages ==="
apt-get update -qq
apt-get install -y -qq curl unzip openssl iptables python3 nginx certbot python3-certbot-nginx

if ! command -v docker >/dev/null; then
  echo "=== 1b. Docker (official script; read it before running in production) ==="
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
fi
docker --version

echo "=== 2. Swap (only if RAM < 1 GB and little swap) ==="
MEM="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
SW="$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)"
if [ "$MEM" -lt 1024 ] && [ "$SW" -lt 512 ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "2G swap added"
else echo "RAM ${MEM}MB / swap ${SW}MB — no swap change"; fi

echo "=== 3. Xray ==="
if ! command -v /usr/local/bin/xray >/dev/null; then
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
/usr/local/bin/xray version | head -1

echo "=== 4. Install repo copy on the VPS ==="
mkdir -p "$DEST" "$BASE" /etc/nginx/portal-locations /var/www/portal
cp -r "$REPO_DIR"/install.sh "$REPO_DIR"/scripts "$REPO_DIR"/templates \
      "$REPO_DIR"/README.md "$REPO_DIR"/SKILL.md "$REPO_DIR"/LICENSE "$DEST"/ 2>/dev/null || true
chmod +x "$DEST/install.sh" "$DEST/scripts"/*.sh

echo "=== 5. Main Xray config (VLESS+WS 127.0.0.1:10000 /vless) ==="
if [ -f /usr/local/etc/xray/config.json ] && grep -qoE '"id": "[0-9a-f-]{36}"' /usr/local/etc/xray/config.json; then
  UUID="$(grep -oE '"id": "[0-9a-f-]{36}"' /usr/local/etc/xray/config.json | head -1 | cut -d'"' -f4)"
  echo "reusing existing UUID from current config"
else
  UUID="$(/usr/local/bin/xray uuid)"
  echo "generated new UUID"
fi
cp /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
sed "s|<YOUR_UUID>|$UUID|g" "$DEST/templates/xray-portal.json" > /usr/local/etc/xray/config.json
chmod 600 /usr/local/etc/xray/config.json
/usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json
systemctl enable --now xray 2>/dev/null || systemctl restart xray
systemctl is-active xray

# The client link is a credential: server-side only, mode 600, never in git.
MAIN_LINK="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&fp=chrome&type=ws&host=$DOMAIN&path=%2Fvless#Portal"
printf '%s\n' "$MAIN_LINK" > /usr/local/etc/xray/client.txt
chmod 600 /usr/local/etc/xray/client.txt

echo "=== 6. nginx portal (self-signed first, then Let's Encrypt) ==="
cp "$DEST/templates/portal-index.html" /var/www/portal/index.html
write_nginx() { # write_nginx <cert_file> <key_file>
  # Order matters: swap the cert paths FIRST (they contain <YOUR_DOMAIN>),
  # then replace the remaining <YOUR_DOMAIN> tokens (server_name).
  sed -e "s|/etc/letsencrypt/live/<YOUR_DOMAIN>/fullchain.pem|$1|g" \
      -e "s|/etc/letsencrypt/live/<YOUR_DOMAIN>/privkey.pem|$2|g" \
      -e "s|<YOUR_DOMAIN>|$DOMAIN|g" \
      "$DEST/templates/nginx-portal.conf" > /etc/nginx/sites-available/portal
}
mkdir -p /etc/nginx/ssl
if [ ! -f /etc/nginx/ssl/portal.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout /etc/nginx/ssl/portal.key -out /etc/nginx/ssl/portal.crt \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN"
  chmod 600 /etc/nginx/ssl/portal.key
fi
write_nginx /etc/nginx/ssl/portal.crt /etc/nginx/ssl/portal.key
ln -sf /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx 2>/dev/null || systemctl reload nginx

echo "=== 7. Let's Encrypt certificate ==="
certbot certonly --webroot -w /var/www/portal -d "$DOMAIN" \
  --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring
write_nginx "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
nginx -t && systemctl reload nginx
systemctl is-active nginx
# certbot installs its own renewal timer on Ubuntu; verify it exists.
systemctl is-enabled certbot.timer 2>/dev/null || echo "note: certbot.timer not found — check 'systemctl list-timers' and renewal manually"

echo "=== 8. Verify ==="
curl -s -o /dev/null -w "portal HTTPS %{http_code}\n" "https://127.0.0.1/"
WS_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  "https://127.0.0.1/vless" || true)"
echo "WS handshake via nginx: HTTP $WS_CODE (101 = Xray answered)"

echo "=== 9. Residential lines (optional) ==="
if [ -n "$SKIP_HOMELINE" ]; then
  echo "skipped (--skip-homeline). Add a country later with:"
  echo "  $DEST/scripts/add-country.sh --country JP --name jp --domain $DOMAIN"
elif [ -n "$COUNTRIES" ]; then
  IFS=',' read -ra CC_LIST <<< "$COUNTRIES"
  for c in "${CC_LIST[@]}"; do
    c="$(echo "$c" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
    [ -n "$c" ] || continue
    "$DEST/scripts/add-country.sh" --country "$(echo "$c" | tr '[:lower:]' '[:upper:]')" \
      --name "$c" --domain "$DOMAIN" || echo "WARNING: country $c failed — portal still works; retry add-country.sh later"
  done
else
  echo "no --countries given. Add one later with:"
  echo "  $DEST/scripts/add-country.sh --country JP --name jp --domain $DOMAIN"
fi

echo "=== DONE ==="
echo "portal: https://$DOMAIN/ (HTTP 200 expected)"
echo "main link (600, /usr/local/etc/xray/client.txt): $MAIN_LINK"
echo "TREAT THE LINK LIKE A PASSWORD. Never commit it, never send it through a public converter."
echo "status: systemctl status xray nginx | ss -lnt | grep -E ':80|:443|:10000'"
