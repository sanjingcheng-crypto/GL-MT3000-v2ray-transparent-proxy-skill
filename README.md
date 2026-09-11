# GL-MT3000 (OpenWrt) V2Ray Transparent Proxy — WorkBuddy Skill

> 把一台 GL.iNet **MT3000**（或同类 OpenWrt/immortalWrt 路由器）变成**全网透明代理网关**，让连上它 WiFi 的所有设备无需任何客户端配置即可访问全球网络。本仓库是一个 [WorkBuddy](https://www.codebuddy.cn/) **Skill（技能）**，由 AI 助手在对话中自动调用，指导你完成部署与排障。

[English below](#english)

---

## 这个 Skill 能解决什么

- 让 MT3000 下的手机 / 电脑 / 电视**零配置**翻越，不必在每台设备上装代理客户端。
- 诊断"连不上网"的经典坑：**客户端自己的系统代理指向了死 IP**（最常见的"全部网站打不开"元凶，和路由器无关）、DNS `SERVFAIL`、CN 域名被解析到海外 IP 导致卡死、QUIC/HTTP3（UDP 443）绕过代理、IPv6 泄漏。
- 给出经过实战验证的 **xray 1.8.x 独立版 + iptables REDIRECT(TCP) + TPROXY(UDP/443) + smartdns + dnscrypt/AliDNS DoH** 完整链路与启动脚本。
- **自愈 + 看门狗**：xray 崩溃（xray-core 1.8.23 的 SniffQUIC panic）后，脚本内 `while true` 循环约 1 秒重启 xray；再叠加 cron 每分钟看门狗兜底，路由器重启或运行中崩溃均无需人工介入。

> **引擎说明**：路由器上实际运行的是 **Xray-core（xray）1.8.x 独立版**，不是 v2rayN。v2rayN 是 Windows 桌面图形客户端，给终端用户在自己电脑上手动连代理用；本方案把 xray 装进 MT3000 做**全网透明网关**，客户端零配置，因此不需要 v2rayN。（也不要和 v2rayA 混淆——我们停掉它、改用 xray 独立版。）

## 目录结构

```
GL-MT3000-v2ray-transparent-proxy-skill/
├── mt3000-v2ray-transparent-proxy/   # ← 这个文件夹整体复制到 ~/.workbuddy/skills/
│   ├── SKILL.md                      # 技能主说明（含 frontmatter）
│   ├── references/
│   │   └── configs.md               # 可直接复制的配置模板（含 PLACEHOLDER）
│   ├── scripts/
│   │   ├── xray_standalone.sh       # iptables + 启动脚本模板（含 xray 自愈循环）
│   │   └── xray_watchdog.sh         # cron 看门狗：每分钟检查 xray，宕了自动重建整条链路
│   └── companion/                   # 本次会话顺带的家用网络运维脚本（非核心，详见其 README）
├── LICENSE
└── README.md
```

## 支持的操作系统（Supported OS）

- **GL.iNet 官方固件（默认）**：MT3000 出厂自带，底层即 **OpenWrt**（嵌入式 Linux），使用 `opkg` 包管理，进程靠 `/etc/rc.local` 自启。本方案以它为准。
- **immortalWrt**：OpenWrt 衍生固件，同样适用；自启脚本还需检查 `/etc/rc.d/`。
- **不适用**：非 OpenWrt 系路由器（如原厂华硕 / 网件固件、纯 Padavan 等）缺少 `iptables`/`rc.local` 体系，不能直接套用。

> 本质就是 **OpenWrt 系 Linux**（不是桌面 Linux，也没有 systemd）。xray 以独立进程方式运行，由 `scripts/xray_standalone.sh` 拉起并配置 iptables 透明重定向。

## 安装（Install）

> 安装的是 `mt3000-v2ray-transparent-proxy/` 整个文件夹，不是仓库根目录。

```bash
# 1) 克隆仓库
git clone https://github.com/sanjingcheng-crypto/GL-MT3000-v2ray-transparent-proxy-skill.git
cd GL-MT3000-v2ray-transparent-proxy-skill

# 2) 把技能文件夹复制到 WorkBuddy 的 skills 目录（用户级，全项目可用）
cp -r mt3000-v2ray-transparent-proxy ~/.workbuddy/skills/

# Windows（PowerShell）等效：
# Copy-Item -Recurse mt3000-v2ray-transparent-proxy "$env:USERPROFILE\.workbuddy\skills\"
```

复制完成后，在 WorkBuddy 对话里直接说"帮我把 MT3000 配置成透明代理网关"，AI 就会加载这个 Skill 并按 `SKILL.md` 的步骤操作。

> 也可以放进项目级技能目录 `<你的项目>/.workbuddy/skills/`，仅对当前项目生效。

## 使用（Usage）

1. 准备 7 条可用的 `vless` + `reality` + `xtls-rprx-vision` 出站（服务器地址/端口、UUID、reality `publicKey`/`shortId`/`spiderX`）。
2. 把 `references/configs.md` 里的 `PLACEHOLDER_*` 替换成真实值（**本仓库不含任何真实密钥**，请自行填写）。
3. 按 `SKILL.md` 的 Deployment Procedure 推送 4 个文件到路由器并启动；DNS 用 AliDNS DoH 拿真实 CN IP，避免国内站点卡死。
4. 排障时优先查**客户端自身**的 Windows 系统代理与 `HTTPS_PROXY` 环境变量——多数"全站打不开"是它的锅，不是路由器。

## 安全与隐私提示

- 仓库内所有代理密钥均为 `PLACEHOLDER`，**不会泄露你的节点信息**；真实配置只在你自己的路由器上。
- 部署前请按 `SKILL.md` 的 step 0 备份路由器原配置。
- 此方案仅用于你**有权使用的网络环境**，请遵守当地法律法规。

## 推荐 GitHub Topics（提高可发现性）

在仓库 **Settings → About** 里添加以下 Topics，别人搜 `mt3000` / `v2ray` / `workbuddy skill` 时更容易命中：

`workbuddy` · `skill` · `mt3000` · `gl-inet` · `v2ray` · `xray` · `transparent-proxy` · `openwrt` · `reality` · `dns` · `smartdns` · `dnscrypt` · `quic` · `tproxy`

---

## English

Turn a GL.iNet **MT3000** (or any OpenWrt/immortalWrt-class router running xray 1.8.x) into a
**transparent proxy gateway**: every device on its WiFi/LAN reaches the global internet with **zero
client-side proxy config**. This repo is a [WorkBuddy](https://www.codebuddy.cn/) **Skill** that an AI
agent loads to guide deployment and troubleshooting.

### What it solves
- Global, config-free browsing for all WiFi clients behind the MT3000.
- Diagnoses the classic failure modes: a client's own stale system proxy pointing at a dead IP (the
  #1 cause of "all sites fail", unrelated to the router), DNS `SERVFAIL`, CN domains resolving to
  overseas IPs and hanging, QUIC/HTTP3 (UDP 443) bypassing the proxy, and IPv6 leaks.
- Provides a proven chain: **standalone xray 1.8.x + iptables REDIRECT (TCP) + TPROXY (UDP/443) +
  smartdns + dnscrypt/AliDNS DoH**, plus a ready startup script.

> **Engine note:** the router actually runs **Xray-core (xray) 1.8.x standalone**, not v2rayN. v2rayN is a
> Windows GUI client for end-users to connect manually; this skill installs xray into the MT3000 as a
> **transparent gateway**, so no client app is needed. (Also distinct from v2rayA — we stop it and use
> xray standalone instead.)

### Install
```bash
git clone https://github.com/sanjingcheng-crypto/GL-MT3000-v2ray-transparent-proxy-skill.git
cp -r GL-MT3000-v2ray-transparent-proxy-skill/mt3000-v2ray-transparent-proxy ~/.workbuddy/skills/
```
Then just ask WorkBuddy to set up the MT3000 transparent proxy in a conversation.

### Notes
- All proxy secrets in this repo are `PLACEHOLDER` tokens — nothing sensitive is committed.
- Fill `PLACEHOLDER_*` in `references/configs.md` with your own 7 `vless`+`reality` outbounds.
- Use only on networks you are authorized to operate; comply with local laws.

### Suggested GitHub Topics
`workbuddy` `skill` `mt3000` `gl-inet` `v2ray` `xray` `transparent-proxy` `openwrt` `reality` `dns` `smartdns` `dnscrypt` `quic` `tproxy`

### Supported OS

- **GL.iNet stock firmware (default):** ships on the MT3000; it is **OpenWrt**-based embedded Linux, uses `opkg`, and auto-starts processes via `/etc/rc.local`. This skill assumes this.
- **immortalWrt:** an OpenWrt derivative; also works, but also check `/etc/rc.d/` for the autostart hook.
- **Not supported:** non-OpenWrt routers (stock Asus/Netgear firmware, pure Padavan, etc.) lack the `iptables`/`rc.local` tooling and cannot reuse this directly.

> In short, it is **OpenWrt-class Linux** (not desktop Linux, no systemd). xray runs as a standalone process launched by `scripts/xray_standalone.sh`, which sets up the iptables transparent redirect.

## 跨平台可用（Cross-platform portability）

本仓库**不只是 WorkBuddy 专用**。其中的知识（`SKILL.md` 正文）、配置模板（`references/configs.md`）与脚本（`scripts/xray_standalone.sh`）都是**平台无关的纯文本**，可在任何能读取 Markdown / Shell 的 AI 代理平台上复用：

- **WorkBuddy**：原生支持——把 `mt3000-v2ray-transparent-proxy/` 整体复制到 `~/.workbuddy/skills/` 即可，AI 会自动加载 `SKILL.md`。
- **Codex / Trae 等（使用 `AGENTS.md` / 项目规则的 IDE 类代理）**：把 `SKILL.md` 的正文内容（去掉顶部 frontmatter）贴进项目的 `AGENTS.md` 或 Rules 即可。
- **Coze 等（Bot / 技能平台）**：将 `SKILL.md` 正文作为 Bot 的知识或自定义技能导入，配置模板与脚本直接引用。

> 唯一随平台变化的是 **SKILL.md 的 frontmatter 包装**（YAML 头部），那是 WorkBuddy 的专属格式；知识本身（部署步骤、DNS 三重坑、诊断矩阵、iptables 脚本）在任何平台都通用。换平台时照抄正文即可，无需重写逻辑。

## Cross-platform portability

This repo is **not WorkBuddy-only**. The knowledge (`SKILL.md` body), the config templates (`references/configs.md`), and the scripts (`scripts/xray_standalone.sh`) are **platform-agnostic plain text**, reusable on any AI-agent platform that can read Markdown/Shell:

- **WorkBuddy:** native support — copy `mt3000-v2ray-transparent-proxy/` into `~/.workbuddy/skills/` and the agent auto-loads `SKILL.md`.
- **Codex / Trae (IDE agents using `AGENTS.md` / project rules):** paste the `SKILL.md` body (minus frontmatter) into the project's `AGENTS.md` or Rules.
- **Coze (bot/skill platforms):** import the `SKILL.md` body as bot knowledge / a custom skill; reference the config templates and scripts directly.

> Only the **SKILL.md frontmatter wrapper** (the YAML header) is WorkBuddy-specific; the substance (deployment steps, the three DNS traps, the diagnosis matrix, the iptables script) is universal. Port the body as-is when switching platforms — no logic rewrite needed.

## License

[MIT](./LICENSE)
