---
name: mt3000-v2ray-transparent-proxy
description: Deploy and troubleshoot a GL.iNet MT3000 (or similar OpenWrt/immortalWrt router) as a transparent proxy gateway using standalone xray/v2ray, iptables REDIRECT (TCP) + TPROXY (UDP/443), smartdns UDP→TCP DNS bridge, and dnscrypt-proxy or AliDNS DoH. This skill should be used when making all WiFi clients reach the global internet through a router, or when diagnosing "cannot open websites", DNS SERVFAIL, QUIC/HTTP3 bypass, overseas-IP routing traps, or "all sites fail on a client but the router is fine" on a transparent-proxy network.
agent_created: true
---

# MT3000 V2Ray Transparent Proxy

## Overview

Turn a GL.iNet MT3000 (or any OpenWrt-class router with xray 1.8.x) into a **transparent proxy gateway**: every device on its WiFi/LAN reaches blocked or overseas sites automatically, with no client-side proxy configuration. The hard part is not the proxy itself but the **DNS chain** and a few **transparent-redirect traps** that silently break specific sites or all traffic. This skill captures the proven architecture and, more importantly, the failure modes that cost hours to find.

## When To Use

- Set up an MT3000 (or similar) so all LAN/WiFi clients browse globally without per-device proxy settings.
- A client "cannot open Baidu / Google / YouTube" while the router itself can.
- DNS returns `SERVFAIL` or resolves CN domains to overseas IPs (e.g. `wshifen.com`).
- QUIC/HTTP3 (UDP 443) bypasses the proxy and leaks.
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

## Recent Field Issues & Fixes (captured 2026-09-11)

These three failures were hit **after the initial deployment went live**, and each is now prevented by a specific setting/script in this skill. Recorded so they are not re-debugged from scratch:

1. **All outbound dead — reality handshake `EOF`.** Root cause: `mux.enabled: true` had crept onto the vless outbounds; mux is incompatible with `xtls-rprx-vision`+`reality`, so the TLS handshake fails. Fix: set `mux.enabled: false` on all `proxy0..6` and **kill the old xray process** (editing the file is not enough — the live process keeps the old config). See *Prerequisites* + *Troubleshooting Matrix*.
2. **Domestic sites slow / hang, foreign sites fine.** Root cause: smartdns upstream was pointed **through the proxy** to query AliDNS; CN DNS then resolved via an overseas exit and returned overseas CDN nodes (`23.53.x`), which `geosite:cn→direct` forced out the dead-direct path, plus IPv6 AAAA with no v6 egress. Fix: smartdns upstream **direct** (AliDNS/Tencent DoH), add xray **DNS split** (`cn-dns` direct / `foreign-dns` via proxy) and `"queryStrategy": "UseIPv4"`. See *DNS Strategy*.
3. **Gradual slowdown to 5–9 s after running a while, no crash.** Root cause: xray **runtime degradation** — the process stays up but its connection table fills with dead `SYN_SENT`/`FIN_WAIT1` sockets, so direct throughput drops ~50×; the old liveness-only watchdog never fired. Fix: deploy `xray_healthcheck.sh` (Layer-3 probe, kills xray when Baidu >2 s, supervisor respawns clean). See *Self-Healing & Watchdog → Layer 3*.

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

## Environment / Tooling Gotchas

- **No sftp on MT3000** → push files via `ssh host 'cat > file' < localfile`.
- **`xray -test` uses a dash** (`xray -test -config …`), not `xray test`.
- **Bash tool blocks `powershell -Command` / `cmd /c`** for remote Windows execution → use the **PowerShell tool** with an `@'...'@` heredoc (remote shell is PowerShell). Example: `ssh -i KEY user@host @' ... '@`.
- **Remote PowerShell mangles unescaped double quotes** → use **single quotes** for paths and concatenate with `+` (e.g. `'--user-data-dir=' + $ud`). Avoid `"` in remote scripts.
- **Chrome CDP over SSH is fragile** — a Chrome launched inside an SSH command is killed when that SSH session ends. Prefer `curl`/`Invoke-WebRequest` for verification; only use CDP if you keep the launching SSH session alive in background.
- **Windows `curl.exe` ignores system proxy but the browser honors it** — the core diagnosis trap for "browser dead, curl alive".
- **MT3000 busybox has no `pkill`** → use `pgrep -f '<pattern>'` + `kill -9`. Also `sleep 1.5` (fractional) errors on busybox → use integer `sleep 1`.
- **Force-killing xray over the same SSH session can drop your connection** — the iptables rebuild briefly flaps the redirect and the SSH session rides the LAN via the router, so you'll see `exit 255`. Reconnect; the supervisor has already respawned xray. Expected, not a failure.
- **Firmware upgrade / factory reset wipes the overlay.** The MT3000 rootfs is a ubifs overlay; your `/usr/bin/*` scripts, `/etc/*` configs, `/etc/rc.local` and crontab survive ordinary reboots but are **erased by a firmware upgrade or factory reset**. After either, re-deploy everything and re-install both cron watchdogs. Keep a note (e.g. in long-term memory) that "upgrade ⇒ re-deploy the MT3000 proxy".
- **The operator PC must be on the MT3000 subnet to SSH it** (see Hardware Topology). If you switch the operator PC back to the main LAN/WiFi, `ssh root@192.168.8.1` times out — rejoin the MT3000 WiFi first.

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
