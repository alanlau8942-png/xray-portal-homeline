# Field record — what actually happened

Dated notes from the deployments this repo is built on. Dates are
Asia/Shanghai. "Measured" means somebody actually ran the check; anything
else is labelled as such.

## 2026-11-17 — portal + Homeline on a Singapore VPS (this repo's origin)

Machine: 2 vCPU / 1 GB RAM / 40 GB disk, Ubuntu 24.04, Singapore, fresh
Flexus L instance. 2 GB swap added (fstab). `apt upgrade` + fail2ban done.
Public IP and domain are the operator's — not recorded here.

### Portal (Variant P), built this day

- Xray v26.11.9 installed via the official install script.
- First attempt: VLESS + **Reality on 443**. Failed: the Reality handshake
  was rejected from the operator's network (auth rejections visible in
  Xray debug logs). The same failure repeated for a plain-TLS inbound on
  8443.
- Second attempt: VLESS + WebSocket on 127.0.0.1:10000, path `/vless`,
  behind nginx on port 80. **Worked immediately.**
- nginx then took 443 with a self-signed certificate (interim), then a real
  Let's Encrypt certificate once DNS for the portal subdomain was live.
  Final state: nginx owns 80+443; the main Xray has ONE inbound
  (VLESS+WS 127.0.0.1:10000 `/vless`); Reality and TLS inbounds removed.
- Verified from the operator's phone (Shadowrocket) the same day.

Lesson: on a network path that interferes with Reality/TLS handshakes to a
given VPS IP, WebSocket through nginx on 443 is the pattern that works.
Do not burn hours retrying Reality on the same path — switch transports.

### Homeline residential lines, built the same day

- Docker 29.10.0 installed; gateway image `homeline-gw:v2` built from
  `scripts/gateway.Dockerfile` (Alpine + OpenVPN + microsocks + iptables).
- VPN Gate availability that day: **only JP and KR had any nodes at all.**
  SG / US / CA / DE / GB returned zero rows. The operator had asked for CA;
  it was reported plainly as unavailable — no silent substitution.
- JP line: exit measured as a Sony Network residential IP in Toride
  (AS2527). KR line: exit measured as a Korea Telecom residential IP in
  Busan (AS4766). Both verified from the operator's phone the same day.
- Both lines use the portal variant: standalone Xray VLESS+WS on
  127.0.0.1:11001 (JP, path `/home-jp`) and 127.0.0.1:11002 (KR, path
  `/home-kr`), SOCKS on 127.0.0.1:12081/12082, nginx locations `/home-jp`
  and `/home-kr` on the same domain. The upstream skill's default Reality
  inbounds (31001/31002) were kept as fallback but were unusable from the
  operator's network, same as the main Reality inbound.
- First JP and KR nodes died within ~20 minutes of first working; both were
  re-scanned and swapped (new `client.ovpn` + container restart). The
  client links did not change.
- Kill-switch test (V6: `pkill openvpn` in the gateway → SOCKS must return
  nothing) had **not been run on this deployment** at packaging time. The
  same test passed in the upstream skill's field test (see below) — run it
  once on your own deployment; the procedure is in `SKILL.md`.

### App-layer observations (same day, operator's phone)

- **WeChat image sends fail over the residential exits** (slow volunteer
  upstream, not a size limit). Turning the VPN off restores sending;
  datacenter exits sent images fine.
- **WeChat's content filter blocks VLESS node QR code images.** Workaround:
  send the QR as a file (or via Telegram / email), not as an image message.

## 2026-10-18 / 2026-10-21 — upstream Homeline field tests

Source: the Homeline skill's own test record (512 MB Debian 13 VPS, plus a
GCP e2-micro second machine). Summarised here because this repo reuses its
scripts verbatim.

- KR: exit was a large Korean consumer ISP, `hosting=false`, external
  client `loc=KR`. US: regional ISP, `hosting=false`, but only a handful of
  usable nodes. JP: connected, but the top-ranked nodes were almost all
  SoftEther space (AS36599, `219.100.37.x`) — the operator's own network,
  not consumer broadband; `fetch-candidates.py` skips it by default. UK:
  zero nodes during the test window. GB later failed repeatedly, then
  recovered on its own.
- Kill switch verified: killing OpenVPN in the gateway → SOCKS probe empty
  → no VPS-IP leak → container restarted and reconnected on the same node
  within ~20 s (watchdog `pgrep` fix; the old pidfile check never fired
  because OpenVPN deletes its pidfile on exit).
- Tunnel "false alive" observed: `tun0` up, control channel alive, data
  plane dead. Only a real-traffic probe (`generate_204` through `tun0`)
  catches it — the v2 watchdog exits after 3 misses so Docker restarts it.
- Forced node swap tested once on KR (node deliberately broken → patrol
  found a new KR node on try 1 → `healed with new node`; Xray config and
  `client.txt` md5 unchanged; the unchanged link then passed a real-client
  test with `loc=KR`).
- Cloud DNS black hole: containers inherit the host's metadata resolver
  (e.g. `169.254.169.254`), which becomes unreachable once OpenVPN routes
  `0.0.0.0/1` + `128.0.0.0/1` through the tunnel. Good nodes looked dead
  (`NOEXIT_OR_LEAK` / `NODNS`). Fix: every scan/gateway container runs
  with `--dns 8.8.8.8`.
- Xray 26.x prints `PrivateKey:` / `Password (PublicKey):` from `xray
  x25519` — parse with a case-insensitive regex, and stop if parsing
  returns empty. Ports in Xray configs must be JSON numbers, not strings
  (`cannot unmarshal string into ... uint16`).

## Standing facts (not tied to one date)

- Residential nodes drop and change IP. That is normal, not a fault. The
  operator's job is to check that the country is right and the line still
  connects — not to chase a stable IP.
- A country with no usable nodes for hours/days happens (UK, GB, and on
  2026-11-17 the whole SG/US/CA/DE/GB set). Report it honestly; never
  relabel another country's exit.
- SOCKS auth is the most common self-inflicted failure: `.env` keys must be
  exactly `GATE_USER` / `GATE_PASS`, and the Xray outbound must carry the
  same values. Unauthenticated probes fail in a way that looks like a dead
  tunnel.
