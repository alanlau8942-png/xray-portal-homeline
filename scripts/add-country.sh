#!/bin/bash
# add-country.sh — add one residential-exit country line to the portal stack.
#
# What it does (Variant P, the deployment proven 2026-11-17):
#   1. fetch + scan VPN Gate candidates for the country (TCP first)
#   2. start the per-country gateway container (OpenVPN + microsocks + kill switch)
#   3. write a standalone Xray VLESS+WS inbound on 127.0.0.1:<WS_PORT>,
#      path /home-<name>, SOCKS outbound through the gateway
#   4. register a systemd unit xray-home-<name> and an nginx location
#      /home-<name> on the portal domain, then verify and print the link.
#
# Usage (run on the VPS as root, from the repo checkout):
#   sudo ./scripts/add-country.sh --country JP --name jp --domain <YOUR_DOMAIN>
#   sudo ./scripts/add-country.sh --country KR --name kr --domain <YOUR_DOMAIN> \
#        --ws-port 11002 --socks-port 12082 --tcp-only
#
# Ports default to the first free ones from 11001+ (WS) and 12081+ (SOCKS).
# Requires install.sh to have run first (nginx portal + main Xray present).
# The delivered client link never changes when a node is swapped later —
# only /opt/homeline/<name>/ovpn/client.ovpn is replaced (see heal.sh).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${HOMELINE_BASE:-/opt/homeline}"
IMAGE="${GATEWAY_IMAGE:-homeline-gw:v2}"
CC=""; NAME=""; DOMAIN=""; WS_PORT=""; SOCKS_PORT=""; TCP_ONLY=""; SKIP_QR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --country)    CC="$2"; shift 2;;
    --name)       NAME="$2"; shift 2;;
    --domain)     DOMAIN="$2"; shift 2;;
    --ws-port)    WS_PORT="$2"; shift 2;;
    --socks-port) SOCKS_PORT="$2"; shift 2;;
    --tcp-only)   TCP_ONLY="--tcp-only"; shift;;
    --skip-qr)    SKIP_QR=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$CC" ] && [ -n "$NAME" ] && [ -n "$DOMAIN" ] || {
  echo "usage: $0 --country CC --name name --domain <YOUR_DOMAIN> [--ws-port N] [--socks-port N] [--tcp-only] [--skip-qr]" >&2; exit 2; }
CC="$(echo "$CC" | tr '[:lower:]' '[:upper:]')"
NAME="$(echo "$NAME" | tr '[:upper:]' '[:lower:]')"
command -v docker >/dev/null || { echo "docker not found — run install.sh first" >&2; exit 1; }
command -v /usr/local/bin/xray >/dev/null || { echo "xray not found — run install.sh first" >&2; exit 1; }
[ -f /etc/nginx/sites-enabled/portal ] || { echo "nginx portal site missing — run install.sh first" >&2; exit 1; }
[ -c /dev/net/tun ] || { echo "TUN unavailable — this VPS cannot run the gateway" >&2; exit 1; }

free_port() { # free_port START — first free TCP port >= START
  local p="$1"
  while ss -lnt 2>/dev/null | grep -q ":$p\b"; do p=$((p+1)); done
  echo "$p"
}
[ -z "$WS_PORT" ] && WS_PORT="$(free_port 11001)"
[ -z "$SOCKS_PORT" ] && SOCKS_PORT="$(free_port 12081)"
LINE_DIR="$BASE/$NAME"
XRAY_DIR="/etc/xray-home-$NAME"
[ ! -d "$LINE_DIR" ] || { echo "$LINE_DIR already exists — refusing to overwrite" >&2; exit 1; }
[ ! -e "$XRAY_DIR" ] || { echo "$XRAY_DIR already exists — refusing to overwrite" >&2; exit 1; }
systemctl list-unit-files 2>/dev/null | grep -q "xray-home-$NAME" && { echo "unit xray-home-$NAME already exists" >&2; exit 1; }
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "vpngw-$NAME-gateway" && { echo "container vpngw-$NAME-gateway already exists" >&2; exit 1; }

echo "=== $CC line '$NAME': WS 127.0.0.1:$WS_PORT (path /home-$NAME), SOCKS 127.0.0.1:$SOCKS_PORT ==="

echo "=== 1. Gateway image ==="
if [ -z "$(docker images -q "$IMAGE" 2>/dev/null)" ]; then
  docker build -t "$IMAGE" -f "$REPO_DIR/scripts/gateway.Dockerfile" "$REPO_DIR/scripts"
else echo "image $IMAGE already present"; fi

echo "=== 2. Fetch + scan VPN Gate candidates for $CC ==="
mkdir -p "$BASE/scan-$CC"
printf 'vpn\nvpn\n' > "$BASE/scan-$CC/auth.txt"; chmod 600 "$BASE/scan-$CC/auth.txt"
python3 "$REPO_DIR/scripts/fetch-candidates.py" "$CC" "$BASE/scan-$CC" 8 $TCP_ONLY
VPSIP="$(curl -s -m 10 https://api.ipify.org)"
docker run --rm --dns 8.8.8.8 --memory 48m --cap-add NET_ADMIN --device /dev/net/tun \
  -e VPSIP="$VPSIP" -e LIMIT=8 -v "$BASE/scan-$CC":/scan \
  --entrypoint sh "$IMAGE" /scan.sh "$CC"
[ -f "$BASE/scan-$CC/working-$CC.ovpn" ] || {
  echo "NO WORKING NODE for $CC right now — VPN Gate lists no usable node for this country. Try again later or pick another country. Nothing was changed." >&2; exit 1; }

echo "=== 3. Line dir + gateway container ==="
mkdir -p "$LINE_DIR/ovpn"
printf 'GATE_USER=gw%s\nGATE_PASS=%s\n' "$(openssl rand -hex 3)" "$(openssl rand -hex 16)" > "$LINE_DIR/.env"
chmod 600 "$LINE_DIR/.env"
cp "$BASE/scan-$CC/working-$CC.ovpn" "$LINE_DIR/ovpn/client.ovpn"
cp "$BASE/scan-$CC/auth.txt" "$LINE_DIR/ovpn/auth.txt"
chmod 600 "$LINE_DIR"/ovpn/*
docker run -d --name "vpngw-$NAME-gateway" --restart unless-stopped --dns 8.8.8.8 --memory 48m \
  --cap-add NET_ADMIN --device /dev/net/tun --env-file "$LINE_DIR/.env" \
  -p "127.0.0.1:$SOCKS_PORT:1080" -v "$LINE_DIR/ovpn:/vpn" "$IMAGE"
sleep 30
# shellcheck disable=SC1091
. "$LINE_DIR/.env"
EXIT_IP="$(curl -s -m 20 --socks5-hostname "127.0.0.1:$SOCKS_PORT" --proxy-user "$GATE_USER:$GATE_PASS" https://api.ipify.org || true)"
[ -n "$EXIT_IP" ] || { echo "SOCKS probe returned nothing — see: docker logs --tail 100 vpngw-$NAME-gateway" >&2; exit 1; }
[ "$EXIT_IP" != "$VPSIP" ] || { echo "LEAK: exit == VPS IP — stop, do not deliver this line" >&2; exit 1; }
MEASURED="$(curl -s -m 10 "http://ip-api.com/line/$EXIT_IP?fields=countryCode,city,isp" | tr '\n' ' ' || true)"
echo "SOCKS exit: $EXIT_IP ($MEASURED)"

echo "=== 4. Standalone Xray (WS inbound, SOCKS outbound) ==="
mkdir -p "$XRAY_DIR"
UUID="$(/usr/local/bin/xray uuid)"
sed -e "s|<YOUR_UUID>|$UUID|g" \
    -e "s|/home-<NAME>|/home-$NAME|g" \
    -e "s|\"port\": 11001|\"port\": $WS_PORT|" \
    -e "s|\"port\": 12081|\"port\": $SOCKS_PORT|" \
    -e "s|<GATE_USER>|$GATE_USER|g" \
    -e "s|<GATE_PASS>|$GATE_PASS|g" \
    "$REPO_DIR/templates/xray-home-ws.json" > "$XRAY_DIR/config.json"
chmod 600 "$XRAY_DIR/config.json"
grep -q '<' "$XRAY_DIR/config.json" && { echo "placeholder left in config — aborting" >&2; exit 1; }
/usr/local/bin/xray run -test -c "$XRAY_DIR/config.json"

echo "=== 5. systemd + nginx ==="
sed "s|<NAME>|$NAME|g" "$REPO_DIR/templates/xray-home-ws.service" \
  > "/etc/systemd/system/xray-home-$NAME.service"
systemctl daemon-reload
systemctl enable --now "xray-home-$NAME"
sleep 2
systemctl is-active "xray-home-$NAME"
mkdir -p /etc/nginx/portal-locations
sed -e "s|<NAME>|$NAME|g" -e "s|<XRAY_WS_PORT>|$WS_PORT|g" \
  "$REPO_DIR/templates/nginx-home-location.conf" \
  > "/etc/nginx/portal-locations/home-$NAME.conf"
nginx -t && systemctl reload nginx

echo "=== 6. Verify ==="
WS_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  "https://$DOMAIN/home-$NAME" || true)"
echo "WS handshake via nginx: HTTP $WS_CODE (101 = Xray answered; anything else: check nginx + xray logs)"
EXIT2="$(curl -s -m 20 --socks5-hostname "127.0.0.1:$SOCKS_PORT" --proxy-user "$GATE_USER:$GATE_PASS" https://api.ipify.org || true)"
echo "SOCKS exit still: ${EXIT2:-NONE}"

LINK="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&fp=chrome&type=ws&host=$DOMAIN&path=%2Fhome-$NAME#Home-$CC"
printf '%s\n' "$LINK" > "$XRAY_DIR/client.txt"; chmod 600 "$XRAY_DIR/client.txt"
QR=""
if [ -z "$SKIP_QR" ] && python3 -c "import qrcode" 2>/dev/null; then
  NODE_LINK="$LINK" python3 "$REPO_DIR/scripts/make-qr.py" --output "$XRAY_DIR/node-qr.png" >/dev/null \
    && QR="$XRAY_DIR/node-qr.png"
else
  echo "note: QR skipped (pip install \"qrcode[pil]\" to enable, or use scripts/make-qr.py later)"
fi

echo "=== DONE: $CC line '$NAME' ==="
echo "link (600, $XRAY_DIR/client.txt): $LINK"
[ -n "$QR" ] && echo "QR: $QR"
echo "measured exit: $EXIT_IP ($MEASURED) — exit IP will change over time; that is normal."
echo "status: systemctl status xray-home-$NAME | docker logs --tail 50 vpngw-$NAME-gateway"
echo "swap a dead node later: scripts/heal.sh $CC vpngw-$NAME-gateway $LINE_DIR $SOCKS_PORT"
echo "TREAT THE LINK LIKE A PASSWORD. Never commit it, never send it through a public converter."
