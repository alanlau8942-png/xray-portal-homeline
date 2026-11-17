---
name: xray-portal-homeline
description: "Use when someone wants a permanent personal proxy portal on their own VPS: nginx + Let's Encrypt + Xray VLESS+WebSocket behind one domain, plus optional residential-IP exits (VPN Gate gateway + standalone Xray per country) whose client link never changes when a node is swapped; or to troubleshoot such a portal — Reality failing, a dead country node, SOCKS auth failing, WeChat images failing over a residential exit, or a certificate that did not renew."
---

# xray-portal-homeline — operator playbook

Build a permanent personal portal on your own VPS: nginx owns 80+443 with a
real certificate; the main Xray line is VLESS+WebSocket behind it; each
residential country is an independent line (gateway container + standalone
Xray) behind `/home-<name>` on the same domain. Nothing here is a hosted
service and nothing is shared: one VPS, one operator, one set of links.

## 0. Before anything — read-only scan

Treat the target VPS as unknown. Run the scan first; it installs nothing
and changes nothing:

```bash
bash scripts/scan-vps.sh
```

Hard stops (do not proceed even if told to continue): `/dev/net/tun`
missing or not openable as root; any step that would modify, stop or delete
an existing service, container, panel, config or firewall rule; anything
destructive; unsupported CPU arch; no root/sudo. Every port in the scan
output is "taken" — pick only ports the scan showed free.

Plan defaults (operator may change any item, silence = proceed):
1) Variant P (portal, proven) — Reality only if the operator insists and
   their network path supports it.
2) Countries: none by default; add with `add-country.sh` (JP/KR are the
   historically best-stocked; any country may have zero nodes on a given day).
3) Ports: main WS 10000 (loopback), country WS 11001+ (loopback), country
   SOCKS 12081+ (loopback). Public: only 80+443.
4) Memory: auto-add 2 GB swap when RAM < 1 GB and swap < 512 MB.
5) Docker: install via the official script when absent; reuse as-is when present.
6) Heal patrol: off by default (gateway minute-check stays on).

## 1. Install the portal

```bash
sudo ./install.sh --domain <YOUR_DOMAIN> --email <YOUR_EMAIL> --countries jp,kr
```

What it does, in order: DNS check (the domain must already resolve to the
VPS) → base packages + Docker if missing → swap if needed → Xray via the
official install script → repo copy to `/opt/xray-portal-homeline` →
main Xray config (VLESS+WS 127.0.0.1:10000 `/vless`, fresh UUID, mode 600)
→ nginx site + portal page → self-signed cert so nginx can start → real
Let's Encrypt certificate via webroot → nginx reloaded on the real cert →
optional country lines. Re-running is safe: it reuses the existing UUID
and certificate.

Verify after install (V0):
- `https://<DOMAIN>/` returns 200.
- WebSocket handshake on `/vless` answers 101:
  `curl -sk -i -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" https://<DOMAIN>/vless`
- `systemctl is-active xray nginx` both print `active`.
- Main link is at `/usr/local/etc/xray/client.txt` (600, server-side only).

## 2. Add a residential country line

```bash
sudo /opt/xray-portal-homeline/scripts/add-country.sh --country JP --name jp --domain <YOUR_DOMAIN>
```

Steps inside: build the gateway image once → fetch VPN Gate candidates
(TCP first, by ping then speed, SoftEther space skipped by default) →
scan them in a throwaway container until one works → create
`/opt/homeline/<name>/` with a fresh `.env` (random `GATE_USER`/`GATE_PASS`,
600) → start `vpngw-<name>-gateway` → probe SOCKS exit (must return an IP
that is not the VPS IP, country must match) → write the standalone Xray
config (`/etc/xray-home-<name>/config.json`, VLESS+WS 127.0.0.1:`<WS_PORT>`,
path `/home-<name>`, SOCKS outbound) → `xray run -test` → systemd unit
`xray-home-<name>` → nginx location `/home-<name>` → print the link + QR.

If the scan prints `NO WORKING NODE for <CC>`: that country has no usable
node right now. Say so, try again later or pick another country. Never
substitute another country's nodes.

One line per country, always: fresh name, fresh ports, fresh `.env`,
fresh UUID, own container, own unit, own Xray dir. Never share a SOCKS
port, WS port, directory or credential set between lines.

## 3. Swap a dead node (link unchanged)

A dead node never requires a new client link — only the gateway's
`client.ovpn` changes. Two ways:

**Manual** (works immediately):
```bash
cd /opt/xray-portal-homeline
python3 scripts/fetch-candidates.py <CC> /opt/homeline/scan-<CC> 8 /opt/homeline/<name>/ovpn/client.ovpn
docker run --rm --dns 8.8.8.8 --memory 48m --cap-add NET_ADMIN --device /dev/net/tun \
  -e VPSIP=<VPS_IP> -e LIMIT=8 -v /opt/homeline/scan-<CC>:/scan \
  --entrypoint sh homeline-gw:v2 /scan.sh <CC>
cp /opt/homeline/scan-<CC>/working-<CC>.ovpn /opt/homeline/<name>/ovpn/client.ovpn
chmod 600 /opt/homeline/<name>/ovpn/client.ovpn
docker restart vpngw-<name>-gateway
```

**Automatic (optional patrol):** install the patrol files first, so
`heal.sh` can find them where it expects them:

```bash
mkdir -p /opt/homeline/heal
cp /opt/xray-portal-homeline/scripts/heal.sh /opt/homeline/heal/heal.sh
cp /opt/xray-portal-homeline/scripts/fetch-candidates.py /opt/homeline/fetch.py
cp /opt/xray-portal-homeline/templates/homeline-heal.timer.example \
   /etc/systemd/system/homeline-heal-<cc>.timer
cp /opt/xray-portal-homeline/templates/homeline-heal.service.example \
   /etc/systemd/system/homeline-heal-<cc>.service
# edit the two unit files: replace <cc>/<CC>/<HOMELINE_BASE>/<LINE_DIR>/<SOCKS_PORT>
systemctl daemon-reload
systemctl enable --now homeline-heal-<cc>.timer
```
the SOCKS exit; first `no_exit` failure only restarts the gateway on the
same node; from the 2nd consecutive failure (or immediately on leak/country
mismatch) it rescans and swaps the node. Xray UUID/port/link are never
touched. Read the patrol log after the first run — an armed timer is not
proof it works.

## 4. Verification checklist (nothing ships unverified)

Do every item, in order. A link that has not passed V1–V5 must not be
delivered as "done".

- **V1 SOCKS exit exists:** `. /opt/homeline/<name>/.env; curl -s -m 20 --socks5-hostname 127.0.0.1:<SOCKS_PORT> --proxy-user "$GATE_USER:$GATE_PASS" https://api.ipify.org` returns an IP. Empty after ~1 min: read `docker logs --tail 100 vpngw-<name>-gateway` and classify (no nodes / all AUTH_FAILED / TUN problem / list unreachable). Do not retry blindly more than twice.
- **V2 No leak:** the SOCKS exit IP must differ from the VPS public IP (`curl -s https://api.ipify.org` without proxy). Equal = traffic bypassing the tunnel: stop delivery and fix routing first.
- **V3 Country + ISP measured:** look the exit IP up (e.g. `http://ip-api.com/line/<IP>?fields=countryCode,city,isp`) and record country/city/ISP. Compare with the requested country. A big-brand consumer ISP is consistent with residential; a cloud/hosting org means the node is probably a datacenter in disguise — say so and offer a rotate. Never label it residential on a guess.
- **V4 Real client, end to end (mandatory):** import the exact delivered `vless://` link (or its QR) into a real client on a real device/network, open an IP-lookup page through it, and confirm (a) the page loads, (b) the shown IP/country matches V3 (allowing for the exit having rotated since — re-measure and re-report if it changed). A server-side SOCKS curl is necessary but NOT a substitute: transport/firewall problems only show up from a real client.
- **V5 QR decodes to the same link:** `NODE_LINK='<link>' python3 scripts/make-qr.py --output node-qr.png` then `--verify`. If no decoder is installed it prints `QR_DECODE_SKIPPED` — then the phone scan in V4 is the decode check; say which one actually happened.
- **V6 Kill switch proven (run once per deployment):** `docker exec vpngw-<name>-gateway pkill openvpn` — the SOCKS probe must then return nothing (kill switch), and the container must restart within ~1–3 min (`docker inspect -f '{{.RestartCount}}'`). Dead nodes are swapped by hand or by the heal patrol.

Delivery link format (portal variant, one line per country):

```text
vless://<UUID>@<DOMAIN>:443?encryption=none&security=tls&sni=<DOMAIN>&fp=chrome&type=ws&host=<DOMAIN>&path=%2Fhome-<name>#Home-<MEASURED_CC>
```

Label with the MEASURED country, not only the requested one. Store the link
`600` on the VPS (`/etc/xray-home-<name>/client.txt`). Treat it like a
password.

## 5. Troubleshooting

| Symptom | Likely cause | What to check / do |
|---|---|---|
| Reality handshake never completes, but WS through nginx works | Network path interferes with Reality/TLS to this VPS IP | Stop retrying Reality. Use Variant P (this repo's default). |
| `certbot` fails: domain does not resolve to the VPS | A record missing / not propagated | Point the A record at the VPS IP and wait; re-run install.sh. |
| Portal HTTPS works, `/vless` times out from the phone | nginx location missing, Xray down, or cert path wrong | `nginx -t`, `systemctl status xray`, `ss -lnt \| grep 10000`, check the include file exists in `/etc/nginx/portal-locations/`. |
| A country has no usable nodes for hours/days | Volunteer pool empty for that country | Report honestly; keep retrying or pick another country. Never fabricate a line or relabel another country's exit. |
| Exit is a datacenter/cloud ISP, or country is right but ISP looks like hosting | The "residential" node is a hosted box | Tell the operator it does not look residential, offer rotate; if rotations keep landing on hosting ASNs, say that country's pool looks datacenter-heavy right now. |
| SOCKS auth keeps failing; containers are up | Credential name/value mismatch | `.env` keys must be exactly `GATE_USER`/`GATE_PASS`; Xray outbound user/pass must equal `.env`. This is the single most common self-inflicted failure. |
| Exit IP equals the VPS IP | Tunnel down but SOCKS still answering, or routing broken | Treat as leak: stop delivery, check OpenVPN connected in gateway logs, rescan or run heal.sh; re-run V2 before any delivery. |
| Phone times out, server port reachable, Xray log shows the phone connected, but exit dead | Volunteer node died after the tunnel was up | Not a link problem: do not regenerate the link. Probe SOCKS, then swap the node (Section 3); link stays the same. |
| All lines time out at once | VPS-level event (reboot, Docker down, firewall reset) | Check `systemctl is-active docker`, each `xray-home-<name>`, and `docker ps` first; check the VPS was not suspended. Only then debug lines. |
| Xray fails to start after config edit | Bad config or unparseable keys | `xray run -test -c <config>` and read the error; confirm no `<...>` placeholder is left (`grep -c '<' config.json` must print 0). |
| `cannot unmarshal string into ... uint16` | Port written as a string in config | Ports must be JSON numbers. |
| Gateway restarts / no `tun0` | VPS blocks TUN or lacks NET_ADMIN | `docker logs vpngw-<name>-gateway`; if TUN is forbidden, this VPS cannot host the gateway — say so and stop. |
| Scan/heal finds nothing, every node fails | Node list source unreachable/changed, or pool empty | Check `fetch-candidates.py` output and scan lines; if the source format changed, that is a code fix, not a retry loop. |
| WeChat images fail to send over a residential line | Slow volunteer upstream (observed, not a size limit) | Use the datacenter line or turn the VPN off for sending. |
| WeChat blocks a VLESS QR image | Content filter on QR images | Send the QR as a file (or via Telegram / email), not as an image message. |
| Certificate did not renew | certbot timer missing or port 80 blocked | `systemctl list-timers \| grep certbot`, `certbot renew --dry-run`; port 80 must stay open for webroot renewal. |

## 6. Safety and scope notes

- Personal self-use only: never open the portal or a residential exit to the
  public, never sell access, never share links beyond your own devices.
- The VPS provider, the residential node's operator, and the services
  visited each see their piece. This is not an anonymity system.
- Keep `.env`, configs and links out of git/chat/screenshots. Repo files
  carry placeholders only; `grep -r '<YOUR_'` must find only template
  tokens, never real values.
- SOCKS binds `127.0.0.1` only. Never `0.0.0.0`.
- No-touch rule: if the VPS already runs a panel (3x-ui/x-ui/…), this build
  uses only new directories, containers, units and ports. Never modify,
  restart or rely on the panel's files, processes or ports.
- VPN Gate nodes are volunteers: availability, speed and safety are
  unguaranteed. Do not use for anything unlawful; do not abuse the exit.
- Revoke agent access when done: the key handoff is the operator's to
  remove (`sed -i '/homeline-agent$/d' ~/.ssh/authorized_keys` on the VPS).
