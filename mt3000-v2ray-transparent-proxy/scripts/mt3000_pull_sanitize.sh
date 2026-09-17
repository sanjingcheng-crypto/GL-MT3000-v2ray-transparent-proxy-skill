#!/usr/bin/env bash
# mt3000_pull_sanitize.sh
#
# 一键从 MT3000 拉取最新配置 + 全量脱敏 + 存本机（真实密钥绝不出路由器）。
# 前置：
#   - 本机有 ssh，且能用 KEY 免密登录 ROUTER_HOST（操作机需连 MT3000 WiFi）
#   - 路由器上 /etc/sysupgrade.conf 已含自定义文件路径（否则 sysupgrade -b 不带代理配置）
# 用法（Git Bash）：
#   bash mt3000_pull_sanitize.sh
#   ROUTER_HOST=192.168.8.1 KEY=~/.ssh/id_ed25519_v2raya LOCAL_DEST=/path bash mt3000_pull_sanitize.sh
#
# 产出（LOCAL_DEST）：
#   gl-config-<TS>.sanitized.tar.gz        脱敏版 GL 配置备份（密钥全打码，可随身/可对比，不可直接还原）
#   baseline-iptables/ipset/ps/listeners-<TS>.txt   运行时基线快照（diff 排障用）
#   README-<TS>.txt                        索引
# 同时会在路由器 /root/mt3000_backups/ 更新一份含真实密钥的 .tar.gz（还原用，不外传）。

set -euo pipefail

ROUTER_HOST="${ROUTER_HOST:-192.168.8.1}"
KEY="${KEY:-$HOME/.ssh/id_ed25519_v2raya}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEST="${LOCAL_DEST:-$SCRIPT_DIR}"
ROUTER_BK="/root/mt3000_backups"

TS="$(date +%Y%m%d-%H%M)"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o BatchMode=yes)

echo "[*] 路由器: $ROUTER_HOST   本机目标: $LOCAL_DEST"
echo "[*] 时间戳: $TS"

# ---------- 第 1 步：路由器侧 打包 + 全量脱敏 + 快照 ----------
echo "[1/3] SSH 连路由器，sysupgrade -b 打包并脱敏 etc/v2raya/* ..."
ssh "${SSH_OPTS[@]}" "root@$ROUTER_HOST" "TS=$TS BK=$ROUTER_BK sh -s" <<'RSH'
set -e
TS="${TS:?}"; BK="${BK:?}"
mkdir -p "$BK"
echo "  - sysupgrade -b ..."
sysupgrade -b "$BK/gl-config-$TS.tar.gz"
echo "  - 解包到临时目录，全量脱敏 etc/v2raya/ 所有文本文件"
SAN=/tmp/mt3000_san
rm -rf "$SAN"; mkdir -p "$SAN"
tar xzf "$BK/gl-config-$TS.tar.gz" -C "$SAN"
for f in "$SAN"/etc/v2raya/*; do
  case "$f" in *.db|*.dat) continue;; esac   # 二进制会损坏且可能含配置，跳过
  [ -f "$f" ] || continue
  sed -r -i 's/("id"[[:space:]]*:[[:space:]]*")[^\"]+(")/\1PLACEHOLDER_UUID\2/g' "$f"
  sed -r -i 's/("address"[[:space:]]*:[[:space:]]*")[^\"]+(")/\1PLACEHOLDER_SERVER\2/g' "$f"
  sed -r -i 's/("publicKey"[[:space:]]*:[[:space:]]*")[^\"]+(")/\1PLACEHOLDER_PUBLICKEY\2/g' "$f"
  sed -r -i 's/("shortId"[[:space:]]*:[[:space:]]*")[^\"]+(")/\1PLACEHOLDER_SHORTID\2/g' "$f"
  sed -r -i 's/("serverName"[[:space:]]*:[[:space:]]*")[^\"]+(")/\1PLACEHOLDER_SNI\2/g' "$f"
done
echo "  - 重打包 sanitized"
tar czf "$BK/gl-config-$TS.sanitized.tar.gz" -C "$SAN" .
rm -rf "$SAN"
echo "  - 运行时基线快照"
iptables-save  > "$BK/baseline-iptables-$TS.txt"  2>/dev/null || true
ipset save     > "$BK/baseline-ipset-$TS.txt"     2>/dev/null || true
ps w           > "$BK/baseline-ps-$TS.txt"         2>/dev/null || true
netstat -tulnp > "$BK/baseline-listeners-$TS.txt"  2>/dev/null || true
cat > "$BK/README-$TS.txt" <<RDEF
MT3000 known-good backup set @ $TS
- gl-config-$TS.tar.gz           : GL sysupgrade config backup (REAL secrets, router-local only)
- gl-config-$TS.sanitized.tar.gz : SAME structure but secrets->PLACEHOLDER (safe off-router copy)
- baseline-iptables-$TS.txt      : iptables-save all tables
- baseline-ipset-$TS.txt         : ipset save (wechat_bypass etc.)
- baseline-ps-$TS.txt            : process list
- baseline-listeners-$TS.txt     : netstat -tulnp
RDEF
echo "  done."
RSH

# ---------- 第 2 步：拉取（dropbear 无 sftp，用 ssh cat 通道；二进制保真） ----------
echo "[2/3] 拉取脱敏包 + 基线快照到本机 ..."
mkdir -p "$LOCAL_DEST"
ssh "${SSH_OPTS[@]}" "root@$ROUTER_HOST" "cat $ROUTER_BK/gl-config-$TS.sanitized.tar.gz" > "$LOCAL_DEST/gl-config-$TS.sanitized.tar.gz"
for fn in baseline-iptables-$TS.txt baseline-ipset-$TS.txt baseline-ps-$TS.txt baseline-listeners-$TS.txt README-$TS.txt; do
  ssh "${SSH_OPTS[@]}" "root@$ROUTER_HOST" "cat $ROUTER_BK/$fn" > "$LOCAL_DEST/$fn"
done
gzip -t "$LOCAL_DEST/gl-config-$TS.sanitized.tar.gz" && echo "  gzip 完整性 OK" || { echo "  FAIL: sanitized.tar.gz 损坏" >&2; exit 1; }

# ---------- 第 3 步：本地校验真实密钥=0 ----------
echo "[3/3] 本地校验：脱敏包不应含真实密钥 ..."
rm -rf /tmp/mt3000_chk; mkdir -p /tmp/mt3000_chk
tar xzf "$LOCAL_DEST/gl-config-$TS.sanitized.tar.gz" -C /tmp/mt3000_chk
tot=0
for f in /tmp/mt3000_chk/etc/v2raya/*; do
  case "$f" in *.db|*.dat) continue;; esac
  [ -f "$f" ] || continue
  n=$(grep -Eo '"address"[[:space:]]*:[[:space:]]*"[^\"]+"' "$f" | grep -vc PLACEHOLDER_SERVER); tot=$((tot+n))
  n=$(grep -Eo '"id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"' "$f" | wc -l); tot=$((tot+n))
  n=$(grep -Eo '"publicKey"[[:space:]]*:[[:space:]]*"[^\"]+"' "$f" | grep -vc PLACEHOLDER_PUBLICKEY); tot=$((tot+n))
  n=$(grep -Eo '"shortId"[[:space:]]*:[[:space:]]*"[^\"]+"' "$f" | grep -vc PLACEHOLDER_SHORTID); tot=$((tot+n))
  n=$(grep -Eo '"serverName"[[:space:]]*:[[:space:]]*"[^\"]+"' "$f" | grep -vc PLACEHOLDER_SNI); tot=$((tot+n))
done
rm -rf /tmp/mt3000_chk
if [ "$tot" -eq 0 ]; then
  echo "  PASS: 脱敏包真实密钥残留 = 0"
else
  echo "  FAIL: 检测到 $tot 处真实密钥残留，请检查脱敏逻辑！" >&2
  exit 1
fi
echo "[*] 完成。本机副本: $LOCAL_DEST/"
ls -1 "$LOCAL_DEST/" | sed 's/^/    /'
