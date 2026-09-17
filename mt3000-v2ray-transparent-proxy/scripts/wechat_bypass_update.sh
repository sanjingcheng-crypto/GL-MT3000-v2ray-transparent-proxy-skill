#!/bin/sh
# wechat_bypass_update.sh — App-aware transparent-proxy bypass (template)
#
# Problem: a transparent proxy that hijacks TCP/UDP 443 (REDIRECT/TPROXY) plus
# DNS-redirect makes some apps (WeChat 视频号 / Channels) detect the proxy and
# refuse to load a specific feature. Routing those domains "direct" in xray does
# NOT fix it — the connection is still hijacked by iptables before xray decides.
#
# Fix: put the app's IPs into two ipsets and RETURN them at the TOP of PREROUTING
# (mangle + nat) so they leave with the client's original source IP, bypassing the
# proxy entirely. The app then sees no proxy and the feature loads (fast).
#
# Idempotent: safe to re-run from rc.local / firewall.user / cron.
#
# ADJUST PER SITE:
#   - LAN_GW   : your router LAN IP (factory default 192.168.8.1) used for nslookup
#   - DOMAINS  : the app's signaling + CDN domains (resolve to IPs -> wechat_bypass)
#   - CDN_NETS : foreign generic CDN CIDRs the app uses for media (-> wechat_bypass_cdn)
#                these have CN edge nodes and must go DIRECT, not around the US proxy.

IPSET=wechat_bypass
IPSET_CDN=wechat_bypass_cdn
LAN_GW=192.168.8.1

DOMAINS="qq.com weixin.qq.com weixinbridge.com tencent.com myqcloud.com qpic.cn qlogo.cn gtimg.com gtimg.qq.com txc.qq.com mmbiz.qpic.cn shp.qpic.cn wx.qlogo.cn finder.video.qq.com finderface.weixin.qq.com wxapp.tc.qq.com shortvideo.finder.qq.com isdspeed.qq.com long.open.weixin.qq.com open.weixin.qq.com v.qq.com m.v.qq.com qzone.qq.com"

# Foreign generic CDNs that host 视频号 cover/video fragments (have CN edges, must be direct).
# CDN IPs rotate — keep this list current; refresh via cron.
CDN_NETS="23.61.202.0/24 23.206.203.0/24 23.220.71.0/24 23.220.68.0/24 23.53.118.0/24 23.54.155.0/24 23.55.44.0/24 23.207.194.0/24 23.197.85.0/24 18.65.14.0/24 4.145.79.0/24 4.150.223.0/24"

# 1) ensure ipsets exist
ipset create "$IPSET" hash:ip family inet 2>/dev/null
ipset create "$IPSET_CDN" hash:net family inet 2>/dev/null

# 2) insert RETURN rules at PREROUTING top (mangle + nat). Skip if already present (-C guard).
#    mangle position 1/2 covers UDP/QUIC; must sit ABOVE the TPROXY udp 443 rule.
iptables -t mangle -C PREROUTING -m set --match-set "$IPSET" dst -j RETURN 2>/dev/null || iptables -t mangle -I PREROUTING 1 -m set --match-set "$IPSET" dst -j RETURN
iptables -t nat   -C PREROUTING -m set --match-set "$IPSET" dst -j RETURN 2>/dev/null || iptables -t nat   -I PREROUTING 1 -m set --match-set "$IPSET" dst -j RETURN
iptables -t mangle -C PREROUTING -m set --match-set "$IPSET_CDN" dst -j RETURN 2>/dev/null || iptables -t mangle -I PREROUTING 2 -m set --match-set "$IPSET_CDN" dst -j RETURN
iptables -t nat   -C PREROUTING -m set --match-set "$IPSET_CDN" dst -j RETURN 2>/dev/null || iptables -t nat   -I PREROUTING 2 -m set --match-set "$IPSET_CDN" dst -j RETURN

# 3) re-fill the foreign-CDN set (flush + add; CIDRs are static-ish but cheap to refresh)
ipset flush "$IPSET_CDN" 2>/dev/null
for net in $CDN_NETS; do
  ipset add "$IPSET_CDN" "$net" 2>/dev/null
done

# 4) resolve app domains -> IPs into a temp set, then swap atomically (no empty-set window)
ipset create wechat_tmp hash:ip family inet 2>/dev/null
for d in $DOMAINS; do
  nslookup "$d" "$LAN_GW" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -vE "^(192\.168\.8\.1|127\.|0\.0\.0\.)" \
    | while read -r ip; do ipset add wechat_tmp "$ip" 2>/dev/null; done
done
ipset swap wechat_tmp "$IPSET" 2>/dev/null
ipset destroy wechat_tmp 2>/dev/null

exit 0
