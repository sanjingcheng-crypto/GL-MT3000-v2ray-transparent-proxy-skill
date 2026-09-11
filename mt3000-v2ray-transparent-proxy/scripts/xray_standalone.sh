#!/bin/sh
# Stop v2rayA entirely (its 2.0.5 cannot store reality pbk/sid and clobbers config/iptables)
/etc/init.d/v2raya stop 2>/dev/null
for PID in $(pgrep -f 'v2raya'); do kill -9 "$PID" 2>/dev/null; done

# Kill any running xray / smartdns (busybox has no pkill; use pgrep + kill)
for PID in $(pgrep -f 'xray run'); do kill -9 "$PID" 2>/dev/null; done
for PID in $(pgrep -f 'smartdns'); do kill -9 "$PID" 2>/dev/null; done
for PID in $(pgrep -f 'dnscrypt-proxy'); do kill -9 "$PID" 2>/dev/null; done
sleep 2
if pgrep -f 'xray run' >/dev/null; then
  for PID in $(pgrep -f 'xray run'); do kill -9 "$PID" 2>/dev/null; done
  sleep 2
fi
: > /var/log/xray.log

# --- TCP transparent proxy (scheme B): write directly into PREROUTING, no custom chains.
#     Old scheme referenced custom chains TP_PRE/TP_OUT/TP_RULE that were never created,
#     so every -A TP_* rule failed silently ("No chain/target/match by that name") and
#     client TCP 80/443 was never redirected. Inline rules survive fw3 restart.
# 1) Drop any leftover custom chains from a previous buggy run.
iptables -t nat -F TP_RULE 2>/dev/null; iptables -t nat -X TP_RULE 2>/dev/null
iptables -t nat -F TP_PRE  2>/dev/null; iptables -t nat -X TP_PRE  2>/dev/null
iptables -t nat -F TP_OUT  2>/dev/null; iptables -t nat -X TP_OUT  2>/dev/null
# 2) Clear previously inserted inline rules so re-run stays idempotent.
for d in 192.168.8.0/24 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
  iptables -t nat -D PREROUTING -i br-lan -d $d -j RETURN 2>/dev/null
done
iptables -t nat -D PREROUTING -i br-lan -m mark --mark 0x80/0x80 -j RETURN 2>/dev/null
iptables -t nat -D PREROUTING -i br-lan -p tcp -j REDIRECT --to-ports 52345 2>/dev/null
# 3) RETURN exceptions for private/router ranges (must precede the catch-all REDIRECT).
iptables -t nat -I PREROUTING -i br-lan -d 192.168.8.0/24 -j RETURN
iptables -t nat -I PREROUTING -i br-lan -d 127.0.0.0/8 -j RETURN
iptables -t nat -I PREROUTING -i br-lan -d 10.0.0.0/8 -j RETURN
iptables -t nat -I PREROUTING -i br-lan -d 172.16.0.0/12 -j RETURN
iptables -t nat -I PREROUTING -i br-lan -d 192.168.0.0/16 -j RETURN
iptables -t nat -I PREROUTING -i br-lan -d 100.64.0.0/10 -j RETURN
iptables -t nat -I PREROUTING -i br-lan -m mark --mark 0x80/0x80 -j RETURN
# 4) Catch-all: redirect remaining client TCP to xray transparent inbound (:52345).
#    Appended so it sits after the RETURN/DNS rules above.
iptables -t nat -A PREROUTING -i br-lan -p tcp -j REDIRECT --to-ports 52345

# DNS hijack: redirect client DNS (br-lan) to smartdns on 5334.
# Chain: client -> smartdns :5334 (UDP/TCP) -> dnscrypt-proxy :5333 (DoH) -> xray SOCKS5 :20170 (port 443) -> Cloudflare.
# Do53 to 1.1.1.1 is blocked upstream, so we tunnel DNS over HTTPS through the proxy.
iptables -t nat -D PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-ports 5333 2>/dev/null
iptables -t nat -D PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-ports 5333 2>/dev/null
iptables -t nat -D PREROUTING -i br-lan -p udp --dport 53 -j REDIRECT --to-ports 5334 2>/dev/null
iptables -t nat -D PREROUTING -i br-lan -p tcp --dport 53 -j REDIRECT --to-ports 5334 2>/dev/null
iptables -t nat -I PREROUTING 1 -i br-lan -p udp --dport 53 -j REDIRECT --to-ports 5334
iptables -t nat -I PREROUTING 1 -i br-lan -p tcp --dport 53 -j REDIRECT --to-ports 5334

# Proxy UDP/443 (QUIC) transparently via TPROXY so Chrome's HTTP3 works end-to-end.
iptables -t filter -D FORWARD -i br-lan -p udp --dport 443 -j REJECT 2>/dev/null
iptables -t mangle -C PREROUTING -i br-lan -p udp --dport 443 -j TPROXY --on-port 52346 --on-ip 0.0.0.0 --tproxy-mark 0x1 2>/dev/null || \
  iptables -t mangle -I PREROUTING 1 -i br-lan -p udp --dport 443 -j TPROXY --on-port 52346 --on-ip 0.0.0.0 --tproxy-mark 0x1
ip rule add fwmark 0x1 table 100 2>/dev/null
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null

# IPv6 leak prevention: if the LAN/client gets a v6 address + default route,
# traffic can bypass the proxy via v6. Drop forwarded IPv6 so clients cannot
# escape. The router's own v6 input is left intact.
ip6tables -F FORWARD 2>/dev/null || true
ip6tables -A FORWARD -j DROP 2>/dev/null || true

# Start xray under a supervisor loop so it auto-restarts on crash (e.g. the SniffQUIC
# panic in xray-core 1.8.23). Appended (>>) instead of truncated (>) so crash traces
# survive across restarts. The loop restarts xray within ~1s of any exit.
( while true; do /usr/bin/xray run --config=/etc/v2raya/config.fixed.json >>/var/log/xray.log 2>&1; echo "[watchdog $(date)] xray exited, restarting in 1s" >>/var/log/xray.log; sleep 1; done & )
sleep 4

# Start dnscrypt-proxy
( /usr/sbin/dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml >/tmp/dnscrypt.log 2>&1 & )
sleep 2

# Start smartdns
( /usr/sbin/smartdns -c /etc/smartdns/smartdns.conf >/tmp/smartdns.log 2>&1 & )
sleep 2

echo "xray pid: $(pgrep -f config.fixed | head -1)"
echo "dnscrypt-proxy pid: $(pgrep -f dnscrypt-proxy | head -1)"
echo "smartdns pid: $(pgrep -f smartdns | head -1)"
echo "--- TCP redirect rule (PREROUTING) ---"
iptables -t nat -S PREROUTING | grep -E '52345|RETURN'
echo "--- DNS redirect ---"
iptables -t nat -S PREROUTING | grep -E '5334|5333'
echo "--- listen ports ---"
netstat -tlnp 2>/dev/null | grep -E '5334|5333|52345|20170'
