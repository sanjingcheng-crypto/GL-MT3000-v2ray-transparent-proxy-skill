# Companion — 本会话的配套运维脚本（非核心 Skill）

> 这些脚本是「部署 MT3000 透明代理」那次排障会话里**顺带产出**的家用网络运维工具，
> 与 Skill 核心链路（xray/smartdns/dnscrypt）**无直接依赖**，故单独放 `companion/`，保持核心 Skill 干净。
>
> These are side-product ops scripts from the same troubleshooting session. They are NOT part of
> the core proxy chain; kept here for reference only.

## 文件清单

| 文件 | 用途 | 运行位置 |
|---|---|---|
| `fix-pcC-proxy.ps1` | 清理本机 `HTTP(S)_PROXY` 环境变量 / 注册表系统代理指向的**死代理端口**（Clash/v2rayN 残留），修复 WorkBuddy 等 Electron 应用不能联网。 | 目标 Windows 机（管理员） |
| `pcC-diag.ps1` | 只读体检：主机名、IP、默认路由、已存 WiFi、网卡状态、curl/iperf3 是否可用。 | 目标 Windows 机 |
| `setup-pcC-sshd.ps1` | 在 Windows 上手动安装 OpenSSH Server 并放行 22 端口（**纯 ASCII 版**，避开 PS 5.1 中文乱码）。 | 目标 Windows 机（管理员） |
| `setup-pcC-sshd-v2.ps1` | 同上，但修掉了 v1 的 3 个真实 bug（变量插值、sshd_config 缺失、直接进程无法建会话），并注册为 Windows 服务（自动重启）。**用这个**。 | 目标 Windows 机（管理员） |
| `PC-C-SSH-to-PC-A-操作清单.md` | 让电脑 C 通过 SSH 进电脑 A 清理其死代理的完整人工操作清单。 | 人工阅读 |
| `wifi-speedtest.ps1` | 测「当前连接」的网速：国内/国际延迟 + 通用 CDN 吞吐 + 国内镜像吞吐，追加到 CSV，5 条路径各跑一次横向对比。 | 测试机（管理员） |
| `wifi-speedtest-plan.md` | 5 条待测路径（有线 / D1-2401 2.4G / 5G / GL-MT3000-2D7 2.4G / 5G）的对比方案与公平性说明。 | 人工阅读 |

## ⚠️ 使用前请先脱敏（重要）

这些脚本里硬编码了**本次会话的真实家用网络信息**，公开发布仅作模板参考，**直接拿去跑会失效或暴露你的环境**：

- 本地 IP 段：`192.168.8.x`（MT3000）、`192.168.10.x`（主路由）
- WiFi SSID：`D1-2401` / `D1-2401-5G` / `GL-MT3000-2D7` / `GL-MT3000-2D7-5G`
- 一台机器的 **ED25519 公钥**（已嵌入 `setup-pcC-sshd*.ps1`，用于 PC A→PC C 免密；公钥本身不保密，但请换成你自己的）
- 登录用户名 `onroud` / `Administrator`、主机名 `LIUSHENG-SRV-B`

→ 复用前请全局替换成你自己的网络参数。

## 运行注意（Windows PowerShell 5.1）

- 含中文注释的 `.ps1`（如 `fix-pcC-proxy.ps1`、`wifi-speedtest.ps1`）在 PS 5.1 下需用 **UTF-8 with BOM** 保存，否则中文会被 GBK 误读导致语法错误。
  最稳妥：用 VS Code / 记事本「另存为 → 编码 UTF-8 BOM」后再运行，或直接用 PowerShell 7+。
- `setup-pcC-sshd*.ps1` 已写成纯 ASCII，可直接运行。
