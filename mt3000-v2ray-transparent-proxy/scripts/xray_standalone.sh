#!/bin/sh
# xray_standalone.sh — MT3000 transparent proxy chain bootstrap.
# Order: stop v2rayA -> kill stale procs -> iptables -> xray -> dnscrypt-proxy -> smartdns.
# Reboot-safe when appended to /etc/rc.local.

set -e

XRAY_BIN=/usr/bin/xray
XRAY_CFG=/etc/v2raya/config.fixed.json
DNSCRYPT_BIN=/usr/sbin/dnscrypt-proxy
DNSCRYPT_CFG=/etc/dnscrypt-proxy/dnscrypt-proxy.toml
SMARTDNS_BIN=/usr/sbin/smartdns
SMARTDNS_CFG=/etc/smartdns/smartdns.conf

# ---- 1. stop v2rayA and kill stale processes ----
/etc/init.d/v2raya stop 2>/dev/null || true
for p in xray dnscrypt-proxy smartdns; do
  for PID in $(pgrep -f "$p"); do kill -9 "$PID" 2>/dev/null; done
done
sleep 1

# ---- 2. iptables: transparent redirect (TCP) + TPROXY (UDP/443) + DNS hijack ----
# TCP -> xray transparent inbound 52345
iptables -t nat -N XRAY_REDIRECT 2>/dev/null || iptables -t nat -F XRAY_REDIRECT
iptables -t nat -A XRAY_REDIRECT -p tcp -j REDIRECT --to-ports 52345

# UDP/443 (QUIC/HTTP3) -> xray TPROXY inbound 52346, marked 0x1
iptables -t mangle -N XRAY_TPROXY 2>/dev/null || iptables -t mangle -F XRAY_TPROXY
iptables -t mangle -A XRAY_TPROXY -p udp --dport 443 -j TPROXY --on-port 52346 --tproxy-mark 0x1

# return route for TPROXY-marked packets
ip rule add fwmark 0x1 table 100 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

# DNS hijack: client UDP/TCP 53 -> smartdns 5334
iptables -t nat -N XRAY_DNS 2>/dev/null || iptables -t nat -F XRAY_DNS
iptables -t nat -A XRAY_DNS -p udp --dport 53 -j REDIRECT --to-ports 5334
iptables -t nat -A XRAY_DNS -p tcp --dport 53 -j REDIRECT --to-ports 5334

# wire chains into PREROUTING (LAN clients); exclude router's own management if needed
iptables -t nat -A PREROUTING -j XRAY_REDIRECT
iptables -t nat -A PREROUTING -j XRAY_DNS
iptables -t mangle -A PREROUTING -j XRAY_TPROXY

# ---- 2b. IPv6 leak prevention ----
# If the ISP/LAN hands out IPv6, clients may take an IPv6 default route and bypass the
# proxy entirely (IPv4 rules above don't touch v6). Drop forwarded IPv6 so LAN clients
# cannot escape via v6. The router's own v6 input is left intact.
ip6tables -F FORWARD 2>/dev/null || true
ip6tables -A FORWARD -j DROP 2>/dev/null || true

# ---- 3. start services in dependency order ----
( "$XRAY_BIN" run --config="$XRAY_CFG" >/var/log/xray.log 2>&1 & )
sleep 4
( "$DNSCRYPT_BIN" -config "$DNSCRYPT_CFG" >/tmp/dnscrypt.log 2>&1 & )   # optional, if using Cloudflare DoH
sleep 1
( "$SMARTDNS_BIN" -c "$SMARTDNS_CFG" >/tmp/smartdns.log 2>&1 & )
sleep 2

# ---- 4. status ----
echo "xray:    $(pgrep -f config.fixed | head -1)"
echo "smartdns:$(pgrep -f smartdns | head -1)"
echo "dnscrypt:$(pgrep -f dnscrypt-proxy | head -1)"
echo "--- listen ---"
netstat -tlnp 2>/dev/null | grep -E '52345|52346|5333|5334|20170' || true
echo "--- DNS test ---"
dig +short @127.0.0.1 -p 5334 www.baidu.com 2>&1 | head -1
