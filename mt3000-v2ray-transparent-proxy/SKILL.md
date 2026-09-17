---
name: mt3000-v2ray-transparent-proxy
description: Deploy and troubleshoot a GL.iNet MT3000 (or similar
  OpenWrt/immortalWrt router) as a transparent proxy gateway using standalone
  xray/v2ray, iptables REDIRECT (TCP) + TPROXY (UDP/443), smartdns UDP→TCP DNS
  bridge, and dnscrypt-proxy or AliDNS DoH. This skill should be used when
  making all WiFi clients reach the global internet through a router, or when
  diagnosing "cannot open websites", DNS SERVFAIL, QUIC/HTTP3 bypass,
  overseas-IP routing traps, or "all sites fail on a client but the router is
  fine" on a transparent-proxy network. Also use it when an app (e.g. WeChat
  视频号 / Channels) refuses to load a specific feature because it detects the
  transparent-proxy hijack (the 443 TPROXY/REDIRECT fingerprint), or when a
  site "plays but is slow" because foreign CDN (Akamai/CloudFront) is being
  hijacked around the proxy instead of going direct.
agent_created: true
disable: false
---

# MT3000 V2Ray Transparent Proxy

## Overview

Turn a GL.iNet MT3000 (or any OpenWrt-class router with xray 1.8.x) into a **transparent proxy gateway**: every device on its WiFi/LAN reaches blocked or overseas sites automatically, with no client-side proxy configuration. The hard part is not the proxy itself but the **DNS chain** and a few **transparent-redirect traps** that silently break specific sites or all traffic. This skill captures the proven architecture and, more importantly, the failure modes that cost hours to find.

## When To Use

- Set up an MT3000 (or similar) so all LAN/WiFi clients browse globally without per-device proxy settings.
- A client "cannot open Baidu / Google / YouTube" while the router itself can.
- DNS returns `SERVFAIL` or resolves CN domains to overseas IPs (e.g. `wshifen.com`).
- QUIC/HTTP3 (UDP 443) bypasses the proxy and leaks.
- An app (WeChat 视频号/Channels, etc.) "cannot display / won't load a feature" while normal browsing is fine — suspect **app-side transparent-proxy detection**, not DNS or routing.
- "All sites fail on a client" — first suspect the **client's own proxy setting**, not the router.

## Architecture (proven working chain)

```
Client (WiFi 192.168.8.x)
   │  DNS query (UDP 53) ──iptables NAT PREROUTING──▶ smartdns :5334
   │  TCP 80/443        ──iptables REDIRECT──▶ xray inbound transparent :52345 (TCP)
   │  UDP 443 (QUIC)    ──iptables TPROXY  ──▶ xray inbound transparent-udp :52346
   ▼
smartdns (:5334)  ──▶ AliDNS DoH (direct :443)  ← returns REAL CN IPs for CN domains
                    └─ alt: dnscrypt-proxy (:5333) ──socks5h──▶ xray socks :20170 ──▶ Cloudflare DoH
xray (:52345/:52346)
   ├─ route ip geoip:cn / geoip:private / geosite:cn ──▶ direct (China ISP)
   └─ else ──▶ balancer[proxy0..proxy6] (7× vless+reality+xtls-rprx-vision) ──▶ overseas
xray also exposes socks :20170 / http :20171 (used by dnscrypt-proxy and for tests)
```

**Startup order matters** (each depends on the previous): `xray` → `dnscrypt-proxy` (optional) → `smartdns`. See `scripts/xray_standalone.sh` and `references/configs.md`.

## Hardware Topology

The logical chain above is only half the picture. The **physical device layout** and **which machine you operate from** decide whether you can even reach the router. Capture both.

### Generic target layout
```
[Upstream ISP / WAN]
        │
   ┌────┴──────────────┐
   │  MT3000 router     │  LAN/WiFi gateway = 192.168.8.1
   │  (xray + smartdns  │  also acts as DHCP + DNS server for clients
   │   + dnscrypt)      │
   └────┬──────────────┘
        │ WiFi / LAN (e.g. 192.168.8.0/24)
   ┌────┼───────────────┬──────────────┐
Client A            Client B          Client C
(phone)        (Server B PC)      (laptop / other)
```
- The router IS the gateway **and** DNS server for all clients (DHCP hands out `192.168.8.1` as both).
- Clients need **zero** proxy config — they just join the WiFi and traffic is transparently redirected.

### Example deployment (substitute your own site's values)
> MT3000's factory-default LAN IP is `192.168.8.1`; adjust `<ROUTER_LAN_IP>` if you changed it.
> Keep your real per-site IPs/hostnames in a **private, non-shared** file — never embed them in this reusable skill.
| Device | Role | IP / Network | Notes |
|---|---|---|---|
| MT3000 | transparent proxy gateway | `<ROUTER_LAN_IP>` (factory default `192.168.8.1`), WAN→ISP | runs xray + smartdns + dnscrypt; SSH `root@<ROUTER_LAN_IP>` |
| Server B | Windows 10 client PC | `<CLIENT_IP>` on MT3000 WiFi | example client that had a **stale system proxy `<OLD_PROXY_IP>:<PORT>`** (leftover from a previous network) → fixed by `ProxyEnable=0` |
| Operator PC | the machine running this skill | normally `<OPERATOR_HOME_IP>` on the main LAN `<MAIN_ROUTER_IP>`; temporarily joins MT3000 WiFi as `<OPERATOR_MT3000_IP>` to SSH the router | **must be ON the MT3000 subnet** to reach `<ROUTER_LAN_IP>` / `<CLIENT_IP>` |
| Main router | upstream LAN (NOT the proxy) | `<MAIN_ROUTER_IP>` | irrelevant to the proxy; only matters because the operator PC lives here by default |
| Old/legacy network | — | `<OLD_NETWORK>` | source of the stale `<OLD_PROXY_IP>:<PORT>` proxy leftover on the client |

### Topology facts that cost real time (write these down per site)
- **The operator PC must be on the same subnet as the router** to SSH it. If the operator PC sits on a different subnet than `<ROUTER_LAN_IP>`, SSH times out and you may wrongly suspect the router is down. **Connect the operator PC to the MT3000 WiFi (or wire it) before troubleshooting.** From a client already on the MT3000 subnet, SSH works directly.
- **A client's own network settings are independent of the router.** A client's failure may be its own stale system-proxy (`<OLD_PROXY_IP>:<PORT>`), NOT a router fault — even when both share the same subnet. Never assume "same subnet ⇒ same fate".
- **Two indicator lights**: if the operator PC can reach `<ROUTER_LAN_IP>` but a client cannot open sites → it's a client-side issue (proxy/DNS). If nobody (including `curl -x socks5h` from the router) can reach sites → it's the router chain (xray/smartdns/dnscrypt down, or rc.local not auto-starting after reboot).

### Installed component versions (this deployment, verified live 2026-09-10)
| Component | Version | Binary path | Notes that affect behavior |
|---|---|---|---|
| xray (standalone, **not** v2rayA) | `1.8.23` (go1.22.5 linux/arm64) | `/usr/bin/xray` | does **not** support the native `dns` inbound (`unknown config id: dns`) |
| smartdns | `1.2020.30` | `/usr/sbin/smartdns` | supports `server-https` (DoH) upstream |
| dnscrypt-proxy | `2.1.5` | `/usr/sbin/dnscrypt-proxy` | supports `proxy = 'socks5h://...'` directive (tunnels DoH through xray SOCKS5) |

Re-run `/usr/bin/xray -version`, `/usr/sbin/smartdns -v`, `/usr/sbin/dnscrypt-proxy -version` after any firmware upgrade — the behavior notes above (esp. xray's lack of native DNS, smartdns DoH support) are version-sensitive.

## Prerequisites

- Root SSH to the router (MT3000: `root@<ROUTER_LAN_IP>`, key or password).
- `xray` 1.8.x standalone binary present (NOT v2rayA-managed — stop v2rayA first).
- `smartdns` and `dnscrypt-proxy` binaries on the router (both ship on MT3000).
- 7 working `vless`+`reality`+`xtls-rprx-vision` outbound configs (server addr/port, uuid, reality `publicKey`, `shortId`, `spiderX`, `flow=xtls-rprx-vision`).
- **`mux` MUST be disabled on every proxy outbound.** `mux` (multiplexing) is **incompatible with `xtls-rprx-vision` + `reality`**: with `mux.enabled: true` xray opens the reality TLS handshake with mux framing, the server rejects it (`EOF` / `read tcp ...: unknown error`) and **no outbound tunnel comes up** — it looks exactly like "all sites fail". Set `"mux": { "enabled": false }` on `proxy0..proxy6`. The GUI that generated the configs may turn mux on by default, so verify it in `config.fixed.json`.
- A CN DNS over HTTPS endpoint reachable on :443 (AliDNS `dns.alidns.com`), since upstream **blocks Do53 (port 53) but allows :443**.

## Deployment Procedure

0. **BACK UP first (do not skip).** The router keeps no history; a bad edit is unrecoverable. Before overwriting anything:
   ```bash
   ssh -i KEY root@<ROUTER_LAN_IP> 'cp /etc/v2raya/config.fixed.json /etc/v2raya/config.fixed.json.bak_$(date +%Y%m%d_%H%M); cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak_$(date +%Y%m%d_%H%M); cp /etc/dnscrypt-proxy/dnscrypt-proxy.toml /etc/dnscrypt-proxy/dnscrypt-proxy.toml.bak_$(date +%Y%m%d_%H%M)'
   ```
1. **Stop v2rayA** and kill any stale xray/smartdns/dnscrypt-proxy so ports are free.
2. Write the four files (templates in `references/configs.md`):
   - `/etc/v2raya/config.fixed.json` — xray standalone config (inbounds + 7 outbounds + balancer + routing).
   - `/etc/dnscrypt-proxy/dnscrypt-proxy.toml` — Cloudflare DoH via xray SOCKS5 (optional alt resolver).
   - `/etc/smartdns/smartdns.conf` — binds :5334, upstream = AliDNS DoH (gives real CN IPs).
   - `/usr/bin/xray_standalone.sh` — the startup/iptables script (make executable).
   - `/usr/bin/xray_watchdog.sh` — second-layer watchdog: a cron job checks xray every minute and, if it is not running, re-invokes `xray_standalone.sh` (covers the case where the supervisor subshell itself dies). Copy from `scripts/xray_watchdog.sh`.
3. **Push files without sftp** — the MT3000 has no `sftp-server`, so use stdin redirection:
   ```bash
   ssh -i KEY root@<ROUTER_LAN_IP> 'cat > /etc/smartdns/smartdns.conf' < ./smartdns.conf
   ```
4. **Validate** before restarting:
   ```bash
   ssh ... root@<ROUTER_LAN_IP> '/usr/bin/xray -test -config /etc/v2raya/config.fixed.json'  # note: dash, not space
   ssh ... root@<ROUTER_LAN_IP> '/usr/sbin/dnscrypt-proxy -check -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml'
   ```
5. **Run the chain**: `ssh ... root@<ROUTER_LAN_IP> 'sh /usr/bin/xray_standalone.sh'`.
6. **Make it reboot-safe**: the MT3000 survives reboots ONLY if the chain is re-launched automatically — a frequent cause of "worked once, dead after reboot". Append the start command so it runs **before** the `exit 0` line, and make rc.local executable:
   ```bash
   ssh -i KEY root@<ROUTER_LAN_IP> 'grep -q xray_standalone /etc/rc.local || sed -i "/^exit 0/i sh /usr/bin/xray_standalone.sh" /etc/rc.local; chmod +x /etc/rc.local; cat /etc/rc.local'
   ```
   Verify the line appears above `exit 0`. (On stock OpenWrt the equivalent is `/etc/rc.local`; on immortalWrt also check `/etc/rc.d/`.)
7. **(Recommended) Install the cron watchdog** as a second safety layer — it re-runs `xray_standalone.sh` if xray is ever found not running, covering both reboots *and* mid-session crashes (xray-core 1.8.23 can panic on `SniffQUIC`). See the **Self-Healing & Watchdog** section below for the exact commands.

## Self-Healing & Watchdog (production hardening)

xray-core **1.8.23** on the MT3000 has a known crash: `SniffQUIC` panics and kills the xray process. When xray dies, **every LAN client loses internet** (TCP redirect points at a dead `:52345`; DNS still resolves but nothing routes). Two layers of self-healing make this self-recovering:

**Layer 1 — supervisor loop (inside `xray_standalone.sh`).** xray is launched inside
`( while true; do /usr/bin/xray run ...; sleep 1; done & )`, so it restarts within ~1s of any exit. Verified: `kill -9` on xray → full recovery in ~6s, no manual intervention.

**Layer 2 — cron watchdog (`xray_watchdog.sh`).** Covers the rare case where the supervisor subshell itself is killed. Install once (survives reboot because `crond` is enabled):

```bash
ssh -i KEY root@<ROUTER_LAN_IP> 'cat > /usr/bin/xray_watchdog.sh' < ./scripts/xray_watchdog.sh
ssh -i KEY root@<ROUTER_LAN_IP> 'chmod +x /usr/bin/xray_watchdog.sh'
ssh -i KEY root@<ROUTER_LAN_IP> 'echo "* * * * * /usr/bin/xray_watchdog.sh" | crontab -'
ssh -i KEY root@<ROUTER_LAN_IP> 'crontab -l'
```

The watchdog checks `pgrep -f 'xray run'` every minute; if nothing matches, it re-runs `xray_standalone.sh` (which rebuilds iptables + restarts the full chain). Combined with rc.local (step 6), the router survives both **reboot** and **runtime xray crash** with zero manual action.

> Make sure `crond` is enabled (`/etc/init.d/cron enable; /etc/init.d/cron start`). On GL.iNet stock firmware crond is present; if `crontab -l` shows the line but it never fires, check that the cron service is actually running.

> **iptables scheme note:** `xray_standalone.sh` writes the redirect rules **inline into `PREROUTING`** (with private-range `RETURN` exceptions), not into custom chains. An earlier version referenced custom chains `XRAY_REDIRECT`/`XRAY_TPROXY`/`XRAY_DNS` that were never created, so every `-A XRAY_*` rule failed silently ("No chain/target/match by that name") and client TCP 80/443 was never redirected — the whole LAN looked "dead". The inline form is idempotent (re-run safe) and is what runs on the router today.

**Layer 3 — health probe (`xray_healthcheck.sh`).** Layers 1–2 only detect a **dead** xray. In the field we hit a worse failure: xray stays *alive* but **degrades** — its connection table piles up dead `SYN_SENT`/`FIN_WAIT1` sockets, so direct (CN) throughput drops ~50× (Baidu 0.5 s → 5–9 s) yet `pgrep` still finds it, so the liveness watchdog never fires. `xray_healthcheck.sh` probes Baidu through the proxy port every minute; if the HTTP code ≠ 200 **or** latency > `THRESH_MS` (2000 ms) it `kill -9`s xray and the Layer-1 supervisor respawns a **clean** process. A 120 s cooldown prevents false kills during cold start. Install alongside Layer 2:

```bash
ssh -i KEY root@<ROUTER_LAN_IP> 'cat > /usr/bin/xray_healthcheck.sh' < ./scripts/xray_healthcheck.sh
ssh -i KEY root@<ROUTER_LAN_IP> 'chmod +x /usr/bin/xray_healthcheck.sh'
ssh -i KEY root@<ROUTER_LAN_IP> 'echo "* * * * * /usr/bin/xray_healthcheck.sh" | crontab -'
```

Verify: `sh /usr/bin/xray_healthcheck.sh force-kill` should drop xray and have it back within ~6 s with Baidu returning 200 in <1 s. The `xray_watchdog.sh` and `xray_healthcheck.sh` cron lines coexist; both survive reboot because `crond` is enabled.

## DNS Strategy (the part that actually breaks things)

This is where most time is lost. Three layers of DNS traps:

1. **Do53 is blocked upstream, :443 is open.** A plain `1.1.1.1:53` upstream fails. Use **DNS-over-HTTPS**:
   - *Option A (CN-correct IPs):* `smartdns` → AliDNS DoH directly on :443 (no proxy needed; `dns.alidns.com` is reachable). Returns **real CN IPs** for CN domains — required for the `geosite:cn → direct` rule to work.
   - *Option B (global, proxy-tunneled):* `dnscrypt-proxy` → Cloudflare DoH via `socks5h://127.0.0.1:20170` (xray SOCKS5, which carries :443). Works, but Cloudflare returns **overseas IPs** for CN domains.
2. **The overseas-IP trap (critical):** If a CN domain (e.g. `www.baidu.com`) resolves to an **overseas IP** (`103.235.46.x` / `wshifen.com`) while the routing rule `geosite:cn → direct` is active, xray forces that overseas IP out the **direct** (China) path → it hangs/times out. Two fixes, pick one:
   - Use **AliDNS** (Option A) so CN domains get real CN IPs, and keep `geosite:cn → direct`; **or**
   - Drop the domain-based `geosite:cn → direct` rule and keep only the **IP-based** `geoip:cn → direct`. Then a CN-domain-but-overseas-IP correctly falls through to the proxy (which we proved reaches global sites). Genuinely-CN-IP sites still go direct.
3. **xray 1.8.23 on MT3000 does NOT support the native `dns` *inbound* (`unknown config id: dns`)** — i.e. you cannot make xray itself a DNS *listener* (`protocol: dns` inbound). The top-level `dns` **resolution block** (servers split) is fully supported and is the recommended approach (see trap 4). Keep `smartdns`/`dnscrypt-proxy` as the client-facing resolver; do not try to replace them with an xray `dns` *inbound*.

4. **The "smartdns-upstream-through-proxy" trap (domestic DNS routed overseas).** Do **NOT** put `-proxy` (or any socks/xray upstream) on smartdns's `server-https`/`server-tcp` lines. If smartdns resolves through the proxy, every CN query is answered from an **overseas exit IP**, so AliDNS returns **overseas CDN nodes** (e.g. Akamai `23.53.x`) for CN sites; the `geosite:cn→direct` rule then forces those out the dead-direct path and they **hang**, and the extra proxy round-trip adds a 10–20 s cold-query stall. Keep smartdns upstream **direct** (AliDNS `223.5.5.5` / Tencent `119.29.29.29` DoH on :443).

   **Recommended DNS chain (the one running in this deployment):** xray holds a `dns` block that splits by geosite — `cn-dns` (direct `223.5.5.5`, `domains: ["geosite:cn"]`, `expectIPs: ["geoip:cn"]`) and `foreign-dns` (via `proxy0`), with `"queryStrategy": "UseIPv4"` so xray never emits AAAA. smartdns then just forwards to AliDNS/Tencent DoH **directly** (no `-proxy`) and returns real CN IPs. See `references/configs.md` for the exact blocks.

## Verification & Diagnosis Workflow

Always test **from both ends** to separate "router broken" from "client broken":

**Router side (definitive):**
```bash
# via proxy (proves outbound tunnel + routing)
curl -s -x socks5h://127.0.0.1:20170 -o /dev/null -w "%{http_code}\n" https://www.google.com
# direct from router
curl -s -o /dev/null -w "%{http_code}\n" https://www.baidu.com
# DNS resolution
dig +short @127.0.0.1 -p 5334 www.baidu.com
```

**Client side (the real user experience):**
- **First, check the CLIENT's own proxy setting** — this is the #1 cause of "all sites fail" and is NOT the router:
  ```powershell
  # on the Windows client
  Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
    Select-Object ProxyEnable, ProxyServer
  echo "HTTPS_PROXY=$env:HTTPS_PROXY  HTTP_PROXY=$env:HTTP_PROXY"
  ```
  If `ProxyEnable=1` and `ProxyServer` points to a **stale/dead IP** (e.g. an old network's gateway), the browser tries that dead proxy → every site fails. **The fix is on the client, not the router** (turn off the system proxy or point it at a live proxy). To disable it (run on the client, reversible):
  ```powershell
  Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0 -Type DWord
  Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyServer -Value '' -Type String
  # then restart the browser / re-open the tab
  ```
  Also clear any `HTTPS_PROXY` / `HTTP_PROXY` **environment variables** pointing at a dead address — these affect `curl`, `npm`, `git`, etc. even when the browser is fixed.
- Then test the actual transparent path (bypass any local proxy to isolate):
  ```bash
  curl --noproxy '*' -o /dev/null -w "%{http_code}\n" https://www.google.com
  ```
  `curl.exe` on Windows **ignores the system proxy**, but the **browser honors it** — so a site failing in the browser but succeeding in `curl --noproxy` is the dead-proxy signature.

### App-layer diagnosis (one app's feature fails, everything else works)

When a **specific app feature** is dead (e.g. WeChat 视频号 "不能显示") but normal sites load fine,
the failure is **upstream of the proxy route decision** — you must read what the router actually saw.
We pinpointed the root cause on the MT3000 by reading **5 areas** (top 3 are the smoking guns):

**1. conntrack — what the client actually connected to**
```bash
conntrack -L -s 192.168.8.136            # the client's LAN IP
```
- Look for `udp dpt=443` (QUIC) and whether the **reply source** is the real server or xray
  (`sport=52345` / `sport=52346` = hijacked into the proxy).
- `mark=0` on the reply = the packet went **direct** (bypass working); `mark=...` = went through proxy.
- If the app **never even sends** the video/QUIC request, the app already self-suppressed → proxy-fingerprint detection.

**2. iptables — is the hijack actually in place / is the bypass on top?**
```bash
iptables -t mangle -nvL PREROUTING        # TPROXY udp 443, plus your RETURN bypass at the TOP
iptables -t nat    -nvL PREROUTING        # REDIRECT tcp 443, plus your RETURN bypass at the TOP
```
- The bypass `RETURN` rules **must be at position 1–2**, above TPROXY/REDIRECT; watch the **packet counters** climb after the app runs.
- Wrong order (TPROXY before RETURN) silently defeats the bypass.

**3. xray access log — did the traffic even leave the country?**
Enable in `config.fixed.json` (`"log": {"access": "/tmp/xray_access.log", "loglevel": "info"}`),
then:
```bash
tail -f /tmp/xray_access.log | grep 192.168.8.136
```
- `-> direct` vs `-> proxy0` per target IP. For a CN app, video traffic should be `direct` — if it is,
  the "traffic went abroad" hypothesis is **dead**; the problem is the *hijack*, not the *exit*.

**4. smartdns audit log — what domain/IP did the client actually resolve?**
Enable `audit-enable yes` + `audit-file /tmp/smartdns_audit.log` in `/etc/smartdns/smartdns.conf`,
then:
```bash
tail -f /tmp/smartdns_audit.log | grep 192.168.8.136
```
- Maps the **symptom** to concrete domains/IPs so you can build the `ipset` precisely.

**5. Binary-search validation (proves the proxy is the cause, not a red herring)**
```bash
# pause the whole transparent hijack for the client (RETURN everything from that LAN IP)
iptables -t mangle -I PREROUTING 1 -s 192.168.8.136 -j RETURN
iptables -t nat    -I PREROUTING 1 -s 192.168.8.136 -j RETURN
```
- If the feature **immediately works** → root cause is 100% the proxy fingerprint. Remove the rules after.
  (Do NOT "fix" it by routing the app `direct` in xray — that leaves the iptables hijack and fails.)

**Also rule out (these were checked but were NOT the cause):**
- **DNS egress**: `dig +short @127.0.0.1 -p 5334 <cn-domain>` must return a **CN** IP, not an overseas
  CDN node — smartdns upstream must be **direct** (AliDNS/Tencent DoH), never through the proxy.
- **MTU/MSS**: `iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-to-pmtu`
  present (no fragmentation).
- **Client IPv6**: a v6 default route bypasses the proxy entirely — disable v6 on the client or the LAN.
- **Startup/persistence chain**: `/etc/rc.local`, `/etc/firewall.user`, `/etc/crontabs/root` (bypass refill),
  and `/etc/rc.d/S99xray` (watch for a **double xray instance** if rc.local and init.d both start it).

**BusyBox gotchas when reading these (the hard way):**
- `pgrep -f '<pattern>'` **matches its own SSH command** and can kill your session — prefer `pgrep -x <name>`
  or grab the PID from the listening port (`netstat -lntp` / `ss -lntp`). BusyBox has **no `pkill`/`nohup`**;
  detach with `( cmd & )`.
- `kill -HUP smartdns` **kills the process** (it is not a cache-flush signal on this build) — restart it
  instead: `/etc/init.d/smartdns restart`.
- `nslookup @192.168.8.1` works where `dig` may be absent; pipe through `grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'`.

## Recent Field Issues & Fixes (captured 2026-09-11)

These three failures were hit **after the initial deployment went live**, and each is now prevented by a specific setting/script in this skill. Recorded so they are not re-debugged from scratch:

1. **All outbound dead — reality handshake `EOF`.** Root cause: `mux.enabled: true` had crept onto the vless outbounds; mux is incompatible with `xtls-rprx-vision`+`reality`, so the TLS handshake fails. Fix: set `mux.enabled: false` on all `proxy0..6` and **kill the old xray process** (editing the file is not enough — the live process keeps the old config). See *Prerequisites* + *Troubleshooting Matrix*.
2. **Domestic sites slow / hang, foreign sites fine.** Root cause: smartdns upstream was pointed **through the proxy** to query AliDNS; CN DNS then resolved via an overseas exit and returned overseas CDN nodes (`23.53.x`), which `geosite:cn→direct` forced out the dead-direct path, plus IPv6 AAAA with no v6 egress. Fix: smartdns upstream **direct** (AliDNS/Tencent DoH), add xray **DNS split** (`cn-dns` direct / `foreign-dns` via proxy) and `"queryStrategy": "UseIPv4"`. See *DNS Strategy*.
3. **Gradual slowdown to 5–9 s after running a while, no crash.** Root cause: xray **runtime degradation** — the process stays up but its connection table fills with dead `SYN_SENT`/`FIN_WAIT1` sockets, so direct throughput drops ~50×; the old liveness-only watchdog never fired. Fix: deploy `xray_healthcheck.sh` (Layer-3 probe, kills xray when Baidu >2 s, supervisor respawns clean). See *Self-Healing & Watchdog → Layer 3*.
4. **An app refuses a feature (WeChat 视频号 "不能显示") while all normal sites work** (hit 2026-09-16). Root cause: the transparent proxy hijacks **TCP 443 (REDIRECT→xray)** and **UDP 443 (TPROXY→xray)** plus DNS-redirect to the gateway; WeChat *probes for that proxy fingerprint* and **self-suppresses** the video channel (conntrack shows it never even sends the QUIC/video request). Fix: an **app-aware iptables bypass** (ipset + `PREROUTING` top `RETURN`) so that app's IPs go direct with the original source IP — see the new **App-Aware Bypass** section. Sub-fix for "plays but slow": foreign CDN (Akamai/CloudFront/Azure) was also being hijacked around the US proxy; add those CIDRs to a `wechat_bypass_cdn` set.

5. **Client DNS times out but the router itself resolves fine (hit 2026-09-17).** Symptom: client `nslookup 192.168.8.1` times out, yet `dig`/`curl` *on the router* (loopback, e.g. `@127.0.0.1`) resolves normally — so the router "looks healthy" but every site fails on the client. Root cause: a **stale `iptables -t nat` PREROUTING rule redirects LAN `udp/tcp dpt:53` to a port (e.g. `5334`) that no process listens on** (GL's `dnsproxy` only starts in `secure` DNS mode, not the default `auto`). All client DNS is black-holed. This is a **4th DNS trap** on top of the three in *DNS Strategy*. Fix: repoint the redirect at the live resolver — `iptables -t nat -D PREROUTING -p {tcp,udp} -i br-lan --dport 53 -j REDIRECT --to-ports 5334` then `-I PREROUTING 1 ... --to-ports 53` (dnsmasq). **Verify the redirect target actually listens**: `iptables -t nat -L PREROUTING -nv` shows the `dpt:53` REDIRECT; `netstat -tulnp | grep :<port>` must show a listener or you've found the dead port. Persist a guard in `/etc/firewall.user` so a firewall reload can't resurrect the dead rule.
6. **ChatGPT / Cloudflare-fronted sites lag (page opens, stream stalls), proxy itself healthy (hit 2026-09-17).** Symptom: `curl -x socks5h` to chatgpt.com returns 403 (reachable, GFW not the cause), node RTT ~0.9–1.3 s (fine), router load low — but the browser stutters on every navigation/SSE stream. Root cause: those sites prefer **HTTP/3 QUIC (UDP/443)**; the transparent proxy TPROXY-tunnels UDP/443 into xray whose **VLESS+reality outbound is TCP** — reality tunneling QUIC (large, many-RTT packets) jitters, so the browser tries QUIC → stalls → falls back to H2/TCP, paying that round-trip per resource. Fix (router-wide, idempotent): `iptables -t mangle -D PREROUTING -p udp -i br-lan --dport 443 -j TPROXY --on-port 52346 --on-ip 0.0.0.0 --tproxy-mark 0x1/0xffffffff` then `-I PREROUTING 1 -p udp -i br-lan --dport 443 -j DROP` (force QUIC to fail instantly → fast H2 fallback over the stable TCP proxy path). Persist in `/etc/firewall.user`. Reversible (delete the DROP rule to restore QUIC). Lighter per-device alternative: `chrome://flags/#enable-quic` = Disabled / Firefox `network.http.http3.enabled=false`.

## Backup & Restore (config + runtime baseline, sanitized off-router copy)

GL's one-click *Backup* (`sysupgrade -b`) only packs what `/etc/sysupgrade.conf` lists — by default it **misses every custom file** this deployment relies on. Do this:

1. **Extend `/etc/sysupgrade.conf`** with the non-standard paths so a GL backup carries them:
   `/etc/firewall.user`, `/etc/v2raya/config.fixed.json` (+ `.monbak`), `/etc/smartdns/smartdns.conf`, `/etc/dnsproxy/`, `/root/.ssh/authorized_keys`, `/usr/bin/wechat_bypass_update.sh`.
2. **On-router backup** (real keys stay on the router, never leave it):
   ```bash
   TS=$(date +%Y%m%d-%H%M); BK=/root/mt3000_backups; mkdir -p $BK
   sysupgrade -b $BK/gl-config-$TS.tar.gz
   iptables-save  > $BK/baseline-iptables-$TS.txt
   ipset save     > $BK/baseline-ipset-$TS.txt
   ps w           > $BK/baseline-ps-$TS.txt
   netstat -tulnp > $BK/baseline-listeners-$TS.txt
   ```
   The runtime baselines let you `diff` against a future `iptables-save` to spot rule drift (e.g. the dead-port-5334 trap above) instantly. Restore: GL UI *System → Backup/Restore* uploads the `.tar.gz`, or `sysupgrade -r <file>`.
3. **Off-router sanitized copy** (for diffing / DR — NO secrets): pull the tar, then redact every secret in `etc/v2raya/*.json`, `*.bak_*`, `*.monbak` **and** `config.json` — VLESS uses keys `"id"`(UUID), `"address"`(server), `"publicKey"`, `"shortId"`, `"serverName"`; `config.json` is single-line so `sed` needs `/g`; exclude `*.db`/`*.dat` binaries (corrupt + may hold config). A ready script does all of this: `mt3000_pull_sanitize.sh` (see `scripts/`). **Never commit the un-sanitized tar to GitHub.**

## App-Aware Bypass (when an app detects the transparent proxy)

Some apps (notably **WeChat 视频号 / Channels**) actively probe the network for a transparent-proxy
hijack (TCP/UDP 443 redirected + DNS sent to the gateway) and **refuse to load a specific feature**
when they find it — even though every normal website works fine through the proxy. This is a
**different failure class** from the DNS/routing traps above, and the usual fixes do NOT apply:

- ❌ **Wrong fix (the trap we fell into first):** routing that app's domains `direct` inside xray.
  The connection is still **hijacked by iptables** (REDIRECT/TPROXY) before xray ever sees the
  route decision, so the proxy fingerprint remains and the app still refuses. Changing the xray
  *route* does not remove the iptables *hijack*.
- ✅ **Right fix:** make iptables **return those IPs before** the REDIRECT/TPROXY rules, so the
  traffic leaves with the client's **original source IP** and the app sees no proxy at all.

### Symptoms
- One specific in-app feature fails (video never loads / "不能显示"), but Google/YouTube/Baidu all work.
- Normal browsing is fine on the same client.
- conntrack while the feature is open shows the app sends only signaling (e.g. UDP 2480/2580) and
  **zero QUIC (udp 443)** — the app suppressed the request itself, it was NOT blocked.

### Confirm the root cause by binary-split (do this first)
Pause the **entire** transparent proxy for the LAN and see if the feature recovers. If it does,
the proxy hijack is 100% the cause:
```bash
# suspend: insert a top-of-PREROUTING RETURN that sends all LAN traffic direct
iptables -t mangle -I PREROUTING 1 -i br-lan -j RETURN
iptables -t nat   -I PREROUTING 1 -i br-lan -j RETURN
# ... ask the user to retry the failing feature ...
# restore:
iptables -t mangle -D PREROUTING -i br-lan -j RETURN
iptables -t nat   -D PREROUTING -i br-lan -j RETURN
```
(While suspended, overseas sites will NOT load — that is expected; you are only using this to prove
the cause. A partial test that only returns UDP 443 is NOT enough — WeChat keys off the whole
hijack pattern, not QUIC alone.)

### Permanent fix — ipset + PREROUTING RETURN bypass
Two ipsets and four `RETURN` rules (mangle + nat, **both** tables, inserted at the **top** of
PREROUTING so they sit **above** the TPROXY (udp 443) and REDIRECT (tcp 443) and DNS-redirect rules):
```bash
ipset create wechat_bypass     hash:ip  family inet 2>/dev/null
ipset create wechat_bypass_cdn hash:net family inet 2>/dev/null
# mangle (covers UDP/QUIC) — RETURN must be ABOVE the TPROXY udp 443 rule
iptables -t mangle -I PREROUTING 1 -m set --match-set wechat_bypass     dst -j RETURN
iptables -t mangle -I PREROUTING 2 -m set --match-set wechat_bypass_cdn dst -j RETURN
# nat (TCP)
iptables -t nat   -I PREROUTING 1 -m set --match-set wechat_bypass     dst -j RETURN
iptables -t nat   -I PREROUTING 2 -m set --match-set wechat_bypass_cdn dst -j RETURN
```
- `wechat_bypass` — the app's own domains resolved to IPs (Tencent/WeChat/视频号 signaling + CDN).
- `wechat_bypass_cdn` — **foreign generic CDNs** (Akamai `23.x`, CloudFront `18.65.x`, Azure `4.145/4.150.x`)
  that host the app's cover images / video *fragments*. These have CN edge nodes and should go direct;
  if hijacked they get routed around the US proxy and the feature is **slow** even though it loads.
  Populate with `hash:net` CIDRs (example set that worked: `23.61.202.0/24 23.206.203.0/24 23.220.71.0/24
  23.220.68.0/24 23.53.118.0/24 23.54.155.0/24 23.55.44.0/24 23.207.194.0/24 23.197.85.0/24
  18.65.14.0/24 4.145.79.0/24 4.150.223.0/24`). CDN IPs rotate, so refresh periodically.

The full idempotent maintenance script (DNS-resolves the domains into `wechat_bypass`, flushes and
re-fills `wechat_bypass_cdn`, inserts the RETURN rules with `-C` guards so re-runs are safe) is in
`scripts/wechat_bypass_update.sh`. Use it as the template; adjust the `DOMAINS`/`CDN` lists per app.

### Ordering is the #1 subtlety
The `RETURN` rules MUST be at **PREROUTING position 1–2**. If the TPROXY (udp 443) or REDIRECT
(tcp 443) rule is above them, QUIC/TCP 443 is hijacked *first* and the bypass never triggers. After
installing, verify with `iptables -t mangle -nvL PREROUTING` / `iptables -t nat -nvL PREROUTING`
that the two `RETURN` rules appear **above** the proxy redirect rules, and watch the packet counters
increment on the `wechat_bypass` rules.

### Make it survive reboot
Re-apply on every boot / `fw reload` / CDN rotation:
- `/etc/firewall.user` → re-run `wechat_bypass_update.sh` (fires on `fw reload`, which includes boot).
- `/etc/rc.local` → run it after xray starts, then again ~40 s later (DNS must be up to resolve domains).
- `/etc/crontabs/root` → `*/15 * * * * /usr/bin/wechat_bypass_update.sh` (CDN IPs rotate).
- If `/etc/rc.d/S99xray` exists AND rc.local also launches xray, you get **two xray fighting for
  :52345** — `rm /etc/rc.d/S99xray` so xray is managed solely by rc.local/`xray_standalone.sh`.

### Verify the fix (conntrack proof)
While the feature plays, on the router:
```bash
conntrack -L -p udp -d <app_ip> 2>/dev/null | head      # reply src = original server IP, NOT xray :52345
conntrack -L 2>/dev/null | grep <foreign_cdn_ip>        # reply dst = WAN IP, mark=0  -> went DIRECT, not via proxy
```
`mark=0` + reply destination = the WAN interface IP means the packet left **direct**, bypassing xray.

## Troubleshooting Matrix

| Symptom | Likely cause | Fix |
|---|---|---|
| All sites fail **in browser**, but `curl --noproxy` works on same client | Client Windows system proxy points to dead/stale IP | Turn off client system proxy (`ProxyEnable=0`) or fix `ProxyServer` |
| All sites fail **everywhere**, router `curl -x socks5h` also fails | xray/smartdns/dnscrypt not running (reboot lost rc.local) | Run `xray_standalone.sh`; verify rc.local; check ports |
| `dig @127.0.0.1 -p 5334` → `SERVFAIL` | Do53 upstream blocked / dnscrypt dead | Use AliDNS DoH or dnscrypt via SOCKS5; check :5333 held |
| Google/YouTube work, **Baidu hangs** | CN domain resolved to overseas IP + `geosite:cn→direct` forces direct | Switch to AliDNS (real CN IPs) **or** drop `geosite:cn→direct`, keep `geoip:cn→direct` |
| Some sites load partial / QUIC errors | UDP 443 (HTTP3) bypassing TPROXY | Ensure `iptables -t mangle` TPROXY rule for UDP dport 443 → :52346 + fwmark return route |
| IPv6 sites bypass proxy | Client using IPv6 default route | Disable/block IPv6 on LAN or force IPv4 DNS |
| Baidu works, Google/YouTube fail | `geosite:cn→direct` too broad / proxy down | Verify 7 outbounds up; check balancer |
| 外网全不通，xray 日志 `EOF` / reality 握手失败 | 某条 vless 出站 `mux.enabled: true` 与 `xtls-rprx-vision`+`reality` 互斥 | 所有 proxy 出站设 `mux.enabled: false`；改完须**真杀**旧 xray 进程再重启（只改磁盘配置、内存旧进程仍是旧配置） |
| 国内站（百度）打开慢/卡 10–20s，国外站正常 | smartdns 上游走代理查 AliDNS → 国内 DNS 绕海外 + 返回海外 CDN 节点 + IPv6 无出口失败 | smartdns 上游改**直连** AliDNS/Tencent DoH；xray 加 DNS 分流(`cn-dns` 直连/`foreign-dns` 走代理) + `queryStrategy: UseIPv4` |
| 用一阵后整体变慢(5–9s)，但进程活着、没崩溃 | xray **运行时退化**：内部堆积死连接，旧看门狗只检活不重启 | 部署 `xray_healthcheck.sh` 健康探测(>2s 自动杀)，supervisor 自愈；干净重启即恢复 |
| 固件升级/恢复出厂后代理失效 | ubifs overlay 的自定义部署被清空，仅留出厂配置 | 升级后按本 SKILL 重新部署 4 文件 + 装回两个 cron 看门狗；建议把"升级即重部署"记进长期记忆 |
| 某 App（视频号/微信）某功能打不开，但普通网页正常 | 应用检测到透明代理特征(443 被 REDIRECT/TPROXY 劫持 + DNS 重定向网关)，主动拒载该特性 | **ipset + PREROUTING 顶部 RETURN 让该 IP 直连**（源 IP 原样）；**别**只改 xray 路由出口(无效，连接已被 iptables 劫持)。先用"暂停整网透明代理"二分验证根因 |
| 视频能播但卡/慢 | 视频托管在 Akamai/CloudFront 等国外通用 CDN，被透明代理劫持绕美国节点 | `wechat_bypass_cdn`(hash:net) 覆盖这些 CIDR 一并 bypass；conntrack 看 `mark=0`+回复 dst=WAN IP 确认直连 |
| 拿不准是不是代理导致的某 App 故障 | — | 二分验证：mangle+nat PREROUTING 顶部插 `RETURN all -i br-lan` 暂停整网透明代理，看 App 是否恢复；恢复即坐实根因 |

| Client `nslookup 192.168.8.1` **times out**, but router loopback resolves fine | Stale `nat PREROUTING` redirects LAN `dpt:53` to a **dead/empty port** (no listener) | `iptables -t nat -L PREROUTING -nv` (find `dpt:53` REDIRECT target) + `netstat -tulnp | grep :<port>` (no listener ⇒ dead port); repoint to live dnsmasq :53 |
| ChatGPT/Cloudflare sites open but **stream stalls/lags**, proxy itself healthy (curl=200, RTT~1s) | QUIC (UDP/443) over TPROXY→reality(TCP) jitters; browser retries QUIC then falls back H2 each time | Router-wide: `iptables -t mangle -I PREROUTING 1 -p udp -i br-lan --dport 443 -j DROP` (force H2 fallback); or disable QUIC per-browser |

## Environment / Tooling Gotchas

- **No sftp on MT3000 (dropbear has no sftp subsystem)** → push files via `ssh host 'cat > file' < localfile`; **pulling is symmetric**: `ssh host 'cat <file>' > localfile` (binary-safe, no pty). `scp` fails with `sftp-server: not found` — use the `cat` channel and verify archives with `gzip -t`.
- **Writing a script containing `$(...)` / `$var` INTO a router file must use a quoted heredoc (`<<'EOF'`)** — an unquoted `cat >> f <<EOF` lets the router shell expand `$(...)` *at write time*, leaving empty/garbled lines (e.g. a dead `TPXY=` guard inside `/etc/firewall.user`). Keep `$()` literal in the file so it expands only when the file runs.
- **`xray -test` uses a dash** (`xray -test -config …`), not `xray test`.
- **Bash tool blocks `powershell -Command` / `cmd /c`** for remote Windows execution → use the **PowerShell tool** with an `@'...'@` heredoc (remote shell is PowerShell). Example: `ssh -i KEY user@host @' ... '@`.
- **Remote PowerShell mangles unescaped double quotes** → use **single quotes** for paths and concatenate with `+` (e.g. `'--user-data-dir=' + $ud`). Avoid `"` in remote scripts.
- **Chrome CDP over SSH is fragile** — a Chrome launched inside an SSH command is killed when that SSH session ends. Prefer `curl`/`Invoke-WebRequest` for verification; only use CDP if you keep the launching SSH session alive in background.
- **Windows `curl.exe` ignores system proxy but the browser honors it** — the core diagnosis trap for "browser dead, curl alive".
- **MT3000 busybox has no `pkill`** → use `pgrep -f '<pattern>'` + `kill -9`. Also `sleep 1.5` (fractional) errors on busybox → use integer `sleep 1`.
- **Force-killing xray over the same SSH session can drop your connection** — the iptables rebuild briefly flaps the redirect and the SSH session rides the LAN via the router, so you'll see `exit 255`. Reconnect; the supervisor has already respawned xray. Expected, not a failure.
- **Firmware upgrade / factory reset wipes the overlay.** The MT3000 rootfs is a ubifs overlay; your `/usr/bin/*` scripts, `/etc/*` configs, `/etc/rc.local` and crontab survive ordinary reboots but are **erased by a firmware upgrade or factory reset**. After either, re-deploy everything and re-install both cron watchdogs. Keep a note (e.g. in long-term memory) that "upgrade ⇒ re-deploy the MT3000 proxy".
- **The operator PC must be on the MT3000 subnet to SSH it** (see Hardware Topology). If you switch the operator PC back to the main LAN/WiFi, `ssh root@192.168.8.1` times out — rejoin the MT3000 WiFi first.
- **busybox `netstat -p` shows no PID** → get a process PID via `pgrep -x <exact-name>` or by matching the listening port (`netstat -lntp` / parse `/proc/net/tcp`). Do not rely on `-p`.
- **`pgrep -f '<pattern>'` can match your own SSH session command line** → `kill`ing that PID kills your shell and drops the session (exit 127). Use `pgrep -x <exact process name>` or resolve the PID from the listening port instead of `-f`.
- **`kill -HUP smartdns` KILLS smartdns (it is not a cache-flush signal)** → DNS goes down until you restart it. To flush the DNS cache, restart smartdns (`( /usr/sbin/smartdns -c <conf> & )`) or just wait for TTL — never `kill -HUP` it.
- **Atomic ipset updates:** build into a temp set then `ipset swap <tmp> <real>` + `ipset destroy <tmp>` so lookups never see an empty set mid-update.
- **mangle `PREROUTING` rule ORDER matters** — see *App-Aware Bypass*. A `RETURN` below the TPROXY/REDIRECT rule is dead.

## IPv6 Leak Prevention

A subtle but common bypass: even with the IPv4 rules above perfect, if the LAN/client gets an **IPv6 address + default route**, traffic leaves via v6 and never touches the proxy. Symptoms: "some sites (IPv6-enabled ones) load fine / partially, or the client reaches the internet but not through the proxy".

The startup script already drops forwarded IPv6 (`ip6tables -F FORWARD; ip6tables -A FORWARD -j DROP`) so LAN clients cannot route out via v6. Complementary client-side measures if you still see leaks:
- On the router's LAN interface, **disable IPv6 RA/DHCPv6** (GL.iNet: *Network → LAN → IPv6 settings → disable*) so clients don't get a v6 address at all.
- Or force IPv4-only DNS (`bind-tcp`/`bind` IPv4 only; the smartdns/dnscrypt configs above already bind `0.0.0.0` and never return AAAA unless the upstream does — AliDNS returns AAAA for some CN sites, which is fine since those still go `direct`).

Verify no v6 bypass: from a client, `curl -6 -s -o /dev/null -w "%{http_code}\n" https://www.google.com` should **fail/timeout** (no direct v6 egress), while `curl -4 ...` succeeds via the proxy.

## Resources

- `references/configs.md` — full copy-pasteable config templates (`config.fixed.json`, `dnscrypt-proxy.toml`, `smartdns.conf`) with `PLACEHOLDER` tokens.
- `scripts/xray_standalone.sh` — the iptables + startup script template (REDIRECT TCP→52345, TPROXY UDP/443→52346 with fwmark return, DNS hijack→5334, **xray supervisor loop for self-healing**, process management, correct start order).
- `scripts/xray_watchdog.sh` — cron watchdog: if `pgrep -f 'xray run'` finds nothing, re-run `xray_standalone.sh` (second-layer safety net).
- `scripts/xray_healthcheck.sh` — health probe (Layer 3): if Baidu via the proxy port returns ≠200 or takes >2000 ms, `kill -9` xray so the supervisor respawns a clean process. Catches **runtime degradation** that a liveness-only watchdog misses.
- `scripts/wechat_bypass_update.sh` — app-aware bypass maintenance: resolves app/WeChat/视频号 domains into `wechat_bypass` (hash:ip) and re-fills `wechat_bypass_cdn` (hash:net, foreign CDN CIDRs), then inserts idempotent `PREROUTING` top `RETURN` rules so those IPs skip the transparent proxy. Use as the template for any app that detects the proxy.
