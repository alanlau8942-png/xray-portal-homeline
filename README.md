# xray-portal-homeline

A personal, permanent alternative to throwaway 1-hour proxy nodes: one small
VPS becomes an HTTPS portal serving your own VLESS node, plus optional
**residential-IP exits** (real consumer broadband IPs in a country you pick)
for the services that distrust datacenter IPs.

```
your phone / laptop ── wss://<DOMAIN>/vless ──▶ nginx :443 (Let's Encrypt)
    │                                        └─▶ Xray VLESS+WS 127.0.0.1:10000 ──▶ internet
    └─ wss://<DOMAIN>/home-jp ──▶ nginx ──▶ Xray VLESS+WS 127.0.0.1:11001
                                        └─▶ SOCKS5 (auth, 127.0.0.1 only)
                                            └─▶ gateway container: OpenVPN
                                                └─▶ VPN Gate volunteer node (JP)
                                                    └─▶ internet (exit = residential IP)
```

Field-tested 2026-11-17 on a 2 vCPU / 1 GB Ubuntu 24.04 VPS in Singapore:
main portal line plus JP and KR residential lines, all verified from a real
phone client. See [docs/LESSONS.md](docs/LESSONS.md) for the dated record.
A $0 backup using only free tiers — Vercel Hobby frontend + edgetunnel node
on Cloudflare Pages — is documented in
[docs/free-tier-stack.md](docs/free-tier-stack.md).

## Why this instead of a 1-hour node

Disposable sandbox nodes (e.g. the E2B-based builders going around on X)
die after ~1 hour, the QR code dies with them, and the domain changes on
every rebuild. This stack is the opposite: a real domain, a real
certificate, services that restart themselves, and residential lines whose
client link **never changes** when a dead volunteer node is swapped — only
the gateway's `client.ovpn` is replaced.

## Variants

| | Variant P — portal (default, proven) | Variant R — upstream default |
|---|---|---|
| Transport | VLESS + WebSocket behind nginx on 443, real TLS cert | VLESS + Reality on a public high port (30000–40000) |
| Needs | A domain pointed at the VPS | An open TCP port, no domain needed |
| Use it when | Reality/TLS handshakes to your VPS IP are interfered with, or you want one domain for everything | Your network path supports Reality and you have no domain |

This repo installs **Variant P** by default. Variant R configs live in
`templates/xray-home-reality.json` with the same gateway scripts; the
upstream Homeline skill documents it in full (see Credits).

## Prerequisites

- A Linux VPS with root SSH: Ubuntu 22.04/24.04, x86_64 or ARM64, systemd.
  1 GB RAM is enough (the installer adds a 2 GB swap file when RAM < 1 GB).
- A domain whose A record already points at the VPS (checked by the installer).
- Ports 80 and 443 open in the cloud security group **and** the OS firewall.
- `/dev/net/tun` available (the gateway needs it; most KVM VPS have it).
- For residential lines: nothing else — VPN Gate nodes, Xray and Docker are
  all free; no account, no card, no subscription.

## Quickstart

```bash
git clone https://github.com/<YOU>/xray-portal-homeline.git
cd xray-portal-homeline
sudo ./install.sh --domain <YOUR_DOMAIN> --email <YOUR_EMAIL> --countries jp,kr
```

That installs nginx + Let's Encrypt + the main Xray line, then adds one
residential line per country. The main client link is printed at the end and
saved mode `600` at `/usr/local/etc/xray/client.txt` **on the server** —
it is never written into this repo.

Add a country later:

```bash
sudo /opt/xray-portal-homeline/scripts/add-country.sh --country JP --name jp --domain <YOUR_DOMAIN>
```

## The 3-step flow

1. **Portal** — `install.sh`: nginx + cert + main Xray line (`/vless`).
   Verify: `https://<DOMAIN>/` returns 200; the WebSocket handshake on
   `/vless` answers 101.
2. **Residential exit** — `scripts/add-country.sh --country JP --name jp`:
   fetches VPN Gate candidates for the country, scans them in a throwaway
   container until one works, starts the gateway container
   (`vpngw-jp-gateway`), then a standalone Xray line on
   `127.0.0.1:11001` with path `/home-jp`. Delivered as one `vless://`
   link + QR.
3. **Keep it alive** — the gateway's built-in watchdog checks the tunnel
   every ~60 s and restarts a stalled one (kill switch: a dead tunnel yields
   no traffic, never the VPS IP). Optional `scripts/heal.sh` on a timer
   swaps a permanently dead node; the client link stays the same.

## Port map (defaults)

| Port | Bound to | What |
|---|---|---|
| 80 | nginx | ACME challenge + redirect to HTTPS |
| 443 | nginx | Portal page + `/vless`, `/home-<name>` proxies |
| 10000 | 127.0.0.1 | Main Xray VLESS+WS (`/vless`) |
| 11001+ | 127.0.0.1 | Per-country Xray VLESS+WS (`/home-<name>`) |
| 12081+ | 127.0.0.1 | Per-country gateway SOCKS5 (authenticated) |
| 31001+ | (Variant R only) | Per-country Xray VLESS+Reality, public |

No Xray port is ever exposed directly in Variant P — everything goes
through nginx on 443.

## Lessons learned (short version)

Full dated record: [docs/LESSONS.md](docs/LESSONS.md).

- **WS behind nginx is the durable pattern.** Reality (443) and plain-TLS
  (8443) inbounds failed from the operator's network to this VPS IP while
  WebSocket through nginx worked immediately. If Reality fails for you, do
  not keep retrying it — switch to Variant P.
- **microsocks needs SOCKS5 auth.** Unauthenticated probes fail in a way
  that looks like a dead tunnel. `GATE_USER` / `GATE_PASS` must match in
  `.env` and in the Xray outbound — this is the single most common
  self-inflicted failure.
- **VPN Gate availability is volatile.** On 2026-11-17 only JP and KR had
  any nodes at all (SG/US/CA/DE/GB: zero). A country with no nodes is a
  fact about the volunteer pool, not a bug — never substitute another
  country's nodes and label them as the requested one.
- **Nodes die.** A working node can die within ~20 minutes. The gateway
  restarts a stalled tunnel on the same node; a permanently dead node needs
  a rescan + `client.ovpn` swap (or the optional heal patrol).
- **WeChat image sends fail over residential exits** (slow volunteer
  upstream) but work over the datacenter line or direct. WeChat's content
  filter also blocks VLESS node QR code images — send the QR as a file.
- **Kill-switch test** (`docker exec vpngw-<name>-gateway pkill openvpn` →
  SOCKS must return nothing) is proven in the upstream skill's field test;
  run it once on your own deployment — see `SKILL.md` V6.

## Security notes

- **Personal self-use only.** Never open the portal or a residential exit
  to the public, never sell access, never share links beyond your own devices.
- Treat every `vless://` link, UUID, Reality key, SOCKS password and QR PNG
  like a password: mode `600` on the server, never in git, chat, screenshots
  or a public link converter.
- SOCKS binds `127.0.0.1` only. `0.0.0.0` there is a security incident.
- Residential exits are volunteer networks: the exit IP changes, the node
  operator can see your traffic's destination, and this is not an anonymity
  system. Use it for legitimate personal use only.
- Rotate credentials if a link ever leaks: regenerate the UUID / gateway
  password and re-issue the link; the old one stops working immediately.
- This repo contains **placeholders only** (`<YOUR_UUID>`, `<GATE_USER>`,
  `<GATE_PASS>`, `<YOUR_DOMAIN>`). If `grep -r` finds a real credential in
  your copy, do not push it.

## File layout

```
install.sh                  portal installer (Variant P)
scripts/
  add-country.sh            add one residential country line (portal variant)
  scan-vps.sh               read-only pre-flight scan (run before anything)
  fetch-candidates.py       pull VPN Gate candidates for a country
  scan-node.sh              try candidates until one works
  gateway.Dockerfile        gateway image (OpenVPN + microsocks + watchdog)
  gateway-entrypoint.sh     gateway: kill switch + minute data-plane check
  heal.sh                   optional patrol: swap a dead node, link unchanged
  check-lines.sh            patrol skeleton: probe exits, write status JSON
  make-qr.py                link -> QR PNG (+ decode verification)
templates/
  nginx-portal.conf         nginx site (portal + /vless + per-country include)
  nginx-home-location.conf  one location block per country line
  portal-index.html         plain welcome page
  xray-portal.json          main Xray: VLESS+WS 127.0.0.1:10000 /vless
  xray-home-ws.json         per-country Xray: VLESS+WS + SOCKS outbound
  xray-home-reality.json    per-country Xray: VLESS+Reality (Variant R)
  xray-home-ws.service      systemd unit for a country line
  gateway.env.example       GATE_USER / GATE_PASS placeholders
  gateway-docker-compose.yml optional compose form of one gateway
  homeline-status.example.json  patrol status file shape
  homeline-heal.timer.example / .service.example  optional heal schedule
SKILL.md                    operator playbook (install / add / swap / verify / fix)
docs/LESSONS.md             dated field record (what actually happened)
docs/free-tier-stack.md      $0 backup: Vercel Hobby + edgetunnel on Cloudflare Pages
```

## Credits

- **Homeline residential-exit skill** — the residential-exit half of this
  repo (gateway, scan, heal, patrol, verification checklist) builds on the
  Homeline skill, originally by
  [free-dam-man](https://github.com/free-dam-man) and maintained via the
  fork [hiltonzz/homeline-residential-exit-skill](https://github.com/hiltonzz/homeline-residential-exit-skill)
  (MIT). The portal half (nginx + Let's Encrypt + VLESS+WS behind one
  domain) and the `add-country.sh` glue are this repo's own work, written
  from a deployment that ran the Homeline skill on 2026-11-17 and adapted it
  where Reality did not work.
- Candidate ranking, UDP acceptance and failure-marker skipping ideas: 
  [vpnbox](https://github.com/sajadinmaker/vpnbox) (MIT).
- [Xray-core](https://github.com/XTLS/Xray-core) (MPL-2.0),
  [microsocks](https://github.com/rofl0r/microsocks),
  [VPN Gate](https://www.vpngate.net/) volunteers.

## License

[MIT](LICENSE)

---

## 中文简介

这是一个“长期稳定”的个人代理门户方案：用一台小 VPS + 一个域名，
搭出自己的 VLESS 节点（走 nginx + 免费证书），再按需加日本、韩国等
国家的**住宅 IP 出口**（出口是真实家庭宽带 IP，不是机房 IP）。

和网上流传的 1 小时一次性节点不同：这个是长期跑的，节点死了换一个，
客户端链接不变。不用绑卡、不用付费订阅（VPS 本身除外）。

快速开始：`sudo ./install.sh --domain <你的域名> --email <你的邮箱> --countries jp,kr`

注意：免费住宅节点是志愿者提供的，会掉线、会换 IP；不要用来做违法的
事，也不要把链接公开分享。详细踩坑记录见 [docs/LESSONS.md](docs/LESSONS.md).
