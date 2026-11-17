# The $0 stack: Vercel Hobby frontend + edgetunnel node on Cloudflare Pages

A zero-cost **backup** to this repo's VPS stack. No server to rent, no card
to bind: the frontend lives on Vercel Hobby, the proxy node lives on
Cloudflare Pages via the edgetunnel project. Both free tiers are independent
and do not conflict.

## The principle

edgetunnel is not a server — it is code running on Cloudflare's edge
(Pages Functions, same runtime as Workers). The client (Shadowrocket,
Karing, …) connects to `xxx.pages.dev` over WebSocket + VLESS; the function
checks the UUID, then opens the connection to the target site and pipes the
data back. Cloudflare is the middleman.

Why it is free: Cloudflare's free tier gives 100,000 requests per day, and
one WebSocket connection counts as one request — the data flowing inside the
connection is not billed separately. Personal use never comes close. No card
is bound, so going over the limit only throttles, never charges.

## Vercel Hobby free tier

Checked against Vercel's official docs by @hodu382759 (2026-11-17):

- Bandwidth: 100 GB / month
- Function invocations: 1,000,000
- CDN requests: 1,000,000
- Active CPU: 4 CPU hours
- Image optimization: 5,000 transformations

One limit to remember: Hobby is for **personal, non-commercial** projects
only. A personal blog, a portfolio, or a few small tools will not touch the
caps.

## How the two fit together

The suggested combo is: frontend on Vercel, API on Cloudflare Workers.
edgetunnel **is** the Cloudflare-side piece of that combo.

Can edgetunnel move onto Vercel instead? Not as-is: it is written for the
Cloudflare runtime (KV bindings, Pages Functions). Vercel functions are
short-lived request/response handlers and a poor fit for long-lived
WebSocket tunnels; a Vercel-specific port would be needed, and is not
recommended. The right shape is:

```
static frontend (one HTML file, a blog, tools) ──▶ Vercel Hobby (free)
proxy node (edgetunnel) ──▶ Cloudflare Pages (free)
```

## edgetunnel setup (condensed)

Full step-by-step (Chinese) is kept in the operator's notes; the short form:

1. Register Cloudflare at dash.cloudflare.com (any email, no card).
2. Download the project ZIP from github.com/cmliu/edgetunnel
   (edgetunnel 2.1) — **do not unzip it**, upload it as-is.
3. Cloudflare console → Workers and Pages → Create → Pages →
   Upload assets → name the project (lowercase + hyphens) → upload the ZIP
   → Deploy site. You get `xxx.pages.dev`. Opening it shows a blank page —
   that is the disguise, not an error.
4. Set the `ADMIN` environment variable (all caps) on the **Production**
   environment, value = your own admin password → Save.
5. Redeploy: variables do not apply to the already-deployed version.
   Deployments → Create new deployment → upload the same ZIP again.
6. Create a KV namespace (e.g. `node-kv`), then bind it to the project:
   Settings → Bindings → KV namespace, variable name `KV` (exact, all
   caps) → Save → Retry deployment once.
7. Open `xxx.pages.dev/admin`, log in with the ADMIN password. Copy the
   subscription link that matches your client (universal / Clash /
   sing-box).
8. Import it into the client (Karing: + → import from clipboard → paste →
   save → update the subscription → pick a node → connect).
9. Verify: open ip.sb in a browser — the IP should be a foreign address.

Optional: bind your own domain (must be hosted on Cloudflare) for a more
stable node; add a `KEY` variable for quick subscribe
(`https://your-address/<KEY>`); add a `UUID` variable to fix the UUID
(must be a valid UUIDv4, or every node breaks).

## Gotchas

- `/admin` will not open, or the password keeps failing: the ADMIN variable
  is not on the Production environment, or you did not redeploy after
  setting it.
- Error 1101: KV is not bound correctly — check the variable name is `KV`.
- Subscription imported but every node times out: try another node; if
  still failing, switch to another "preferred" subscription in the panel.
  Different networks need different preferred entries.
- The ADMIN password and the subscription link are the keys to your node.
  Never publish them — they will be abused to burn your quota.

## Trade-offs vs this repo's VPS stack

| | $0 stack (this doc) | VPS stack (this repo) |
|---|---|---|
| Cost | $0 | one cheap VPS (~¥3 for 7 months in our case) |
| Egress IP | shared Cloudflare datacenter IP, easily recognised as a proxy | dedicated VPS IP + optional residential exits |
| Stability | pages.dev can be slow/blocked from some networks; use preferred IPs / custom domain | real domain + certificate, services restart themselves |
| Control | panel only | full server: nginx, Xray, gateways, kill switch |

Use the $0 stack as a free backup. The VPS stack is the stable primary.

## Sources

- edgetunnel: https://github.com/cmliu/edgetunnel (edgetunnel 2.1)
- Tutorial: X @GaryLee1314, 2026-11-17
- Vercel Hobby limits: X @hodu382759, 2026-11-17 (checked against Vercel's
  official docs by the author)

## 中文简介

零成本备用方案：前端放 Vercel Hobby 免费版，后端节点用 edgetunnel 跑在
Cloudflare Pages 上。edgetunnel 不能直接搬到 Vercel（它用 Cloudflare 的
KV 和 Pages 函数，Vercel 的函数也不适合 WebSocket 长连接），正确的拼法
是两边各放各的，都是免费额度，互不冲突。出口是 Cloudflare 机房共享 IP，
容易被认出是代理，只当备用，主力还是这个仓库的 VPS 那套。
