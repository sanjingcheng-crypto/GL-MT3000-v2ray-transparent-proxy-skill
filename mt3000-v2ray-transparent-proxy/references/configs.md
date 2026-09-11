# MT3000 Transparent Proxy — Config Templates

All `PLACEHOLDER` tokens must be replaced with real values. The structure below is the proven working pattern; adapt IPs/ports only if your network differs.

---

## 1. `/etc/v2raya/config.fixed.json` (xray standalone)

```json
{
  "log": { "loglevel": "warning", "access": "/var/log/xray-access.log", "error": "/var/log/xray.log" },
  "inbounds": [
    {
      "tag": "transparent",
      "protocol": "dokodemo-door",
      "listen": "0.0.0.0",
      "port": 52345,
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "routeOnly": false },
      "streamSettings": { "sockopt": { "tproxy": "redirect" } }
    },
    {
      "tag": "transparent-udp",
      "protocol": "dokodemo-door",
      "listen": "0.0.0.0",
      "port": 52346,
      "settings": { "network": "udp", "followRedirect": true },
      "sniffing": { "enabled": true, "destOverride": ["tls"] },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
    },
    {
      "tag": "socks",
      "protocol": "socks",
      "listen": "127.0.0.1",
      "port": 20170,
      "settings": { "auth": "noauth", "udp": true }
    },
    {
      "tag": "http",
      "protocol": "http",
      "listen": "127.0.0.1",
      "port": 20171
    }
  ],
  "outbounds": [
    {
      "tag": "proxy0",
      "protocol": "vless",
      "settings": {
        "vnext": [ { "address": "PLACEHOLDER_SERVER0", "port": PLACEHOLDER_PORT0,
          "users": [ { "id": "PLACEHOLDER_UUID", "flow": "xtls-rprx-vision",
            "encryption": "none" } ] } ],
        "streamSettings": {
          "network": "tcp",
          "security": "reality",
          "realitySettings": {
            "serverName": "PLACEHOLDER_SNI0",
            "publicKey": "PLACEHOLDER_REALITY_PUBKEY",
            "shortId": "PLACEHOLDER_SHORTID",
            "spiderX": "/"
          }
        }
      }
    },
    "proxy1" ... "proxy6"  // repeat proxy0 shape with SERVER1..6 / SNI1..6
    ,
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIP" }
    },
    {
      "tag": "proxy",
      "protocol": "balancer",
      "settings": { "balancers": [ { "tag": "leastPing", "selector": ["proxy0","proxy1","proxy2","proxy3","proxy4","proxy5","proxy6"] } ] }
    }
  ],
  "routing": {
    "balancers": [ { "tag": "leastPing", "selector": ["proxy0","proxy1","proxy2","proxy3","proxy4","proxy5","proxy6"] } ],
    "rules": [
      { "type": "field", "outboundTag": "direct", "domain": ["geosite:cn"] },
      { "type": "field", "outboundTag": "direct", "ip": ["geoip:cn", "geoip:private"] },
      { "type": "field", "outboundTag": "proxy", "balancerTag": "leastPing" }
    ]
  }
}
```

> NOTE: If CN domains resolve to **overseas IPs** (Cloudflare DoH case) and `geosite:cn → direct` makes them hang, **remove the first routing rule** (`geosite:cn`) and keep only the `geoip:cn/private → direct` rule. Then overseas-resolved CN domains fall through to the proxy.

> **CRITICAL additions (these are what make the deployed config actually work — they were missing from earlier drafts and caused real outages):**
>
> 1. **`mux` must be disabled** on every `proxyN` outbound. Add `"mux": { "enabled": false }` at the outbound root (sibling of `settings`). With `xtls-rprx-vision`+`reality`, an enabled mux makes the TLS handshake fail with `EOF` and **no tunnel comes up**.
> 2. **DNS split + IPv4-only** — append this top-level `dns` block to the config (sibling of `inbounds`/`outbounds`/`routing`):
> 3. **`domainStrategy`** — set `"domainStrategy": "IPOnDemand"` inside `routing`.

```json
"dns": {
  "queryStrategy": "UseIPv4",
  "servers": [
    { "tag": "cn-dns", "address": "223.5.5.5", "port": 53,
      "domains": ["geosite:cn"], "expectIPs": ["geoip:cn"], "direct": true },
    { "tag": "foreign-dns", "address": "8.8.8.8", "port": 53,
      "outboundTag": "proxy0" }
  ]
}
```

> With `queryStrategy: UseIPv4`, xray never emits AAAA — important because the MT3000 has **no IPv6 egress**, so a direct IPv6 result would fail. `cn-dns` uses AliDNS `223.5.5.5` directly (real CN IPs for `geosite:cn`); `foreign-dns` resolves through `proxy0` for everything else.

---

## 2. `/etc/dnscrypt-proxy/dnscrypt-proxy.toml` (Cloudflare DoH via xray SOCKS5)

Use this when you want the resolver tunneled through the proxy (global sites). Not needed if using AliDNS (Option A in SKILL.md).

```toml
listen_addresses = ['127.0.0.1:5333']
proxy = 'socks5h://127.0.0.1:20170'
cache = true

[static]
[static.'cloudflare']
stamp = 'sdns://AgcAAAAAAAAABzEuMC4wLjEAEmRucy5jbG91ZGZsYXJlLmNvbQovZG5zLXF1ZXJ5'
```
> **Getting a correct stamp:** a hand-written or truncated stamp fails with `Stamp is too short` / `illegal base64`. Always copy a **full, verified** stamp from the public list at `https://dnscrypt.info/resolvers/` (or `https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md`). The `sdns://...` above is the official Cloudflare-DoH stamp and is known-good. Do **not** invent the `sdns://` prefix or edit the body.

Validate: `dnscrypt-proxy -check -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml`

---

## 3. `/etc/smartdns/smartdns.conf` (AliDNS DoH — real CN IPs)

Preferred upstream so `geosite:cn → direct` works for Baidu etc.

```conf
bind 0.0.0.0:5334
bind-tcp 0.0.0.0:5334
server-https https://dns.alidns.com/dns-query -host-name dns.alidns.com
server-https https://119.29.29.29/dns-query -host-name dns.pub
cache-size 1024
log-level error
```

> **NEVER add `-proxy` (or any socks/xray upstream) to these `server-*` lines.** Routing smartdns through the proxy makes every CN DNS query answer from an overseas exit, returns overseas CDN nodes (`23.53.x`), and (with AAAA) fails because there is no IPv6 egress — domestic sites then hang 10–20 s. Keep the upstreams **direct** (they reach AliDNS/Tencent DoH on :443, which upstream allows even though Do53 is blocked). If `server-https` is unsupported in your smartdns build (1.2020.x), fall back to `dnscrypt-proxy` as the sole resolver and remove the `geosite:cn → direct` rule. Always verify `dig +short @127.0.0.1 -p 5334 www.baidu.com` returns a **CN IP** (e.g. `111.x.x.x` / `a.shifen.com`), not `wshifen.com`.

---

## 4. Push files (no sftp on MT3000)

```bash
KEY=/path/to/router_key
DST=root@<ROUTER_LAN_IP>   # MT3000 factory default is 192.168.8.1; change if you reassigned it
DIR=/path/to/local/configs
ssh -i "$KEY" -o StrictHostKeyChecking=no "$DST" 'cat > /etc/v2raya/config.fixed.json'        < "$DIR/config.fixed.json"
ssh -i "$KEY" -o StrictHostKeyChecking=no "$DST" 'cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml' < "$DIR/dnscrypt-proxy.toml"
ssh -i "$KEY" -o StrictHostKeyChecking=no "$DST" 'cat > /etc/smartdns/smartdns.conf'            < "$DIR/smartdns.conf"
ssh -i "$KEY" -o StrictHostKeyChecking=no "$DST" 'cat > /usr/bin/xray_standalone.sh'           < "$DIR/xray_standalone.sh"
```
