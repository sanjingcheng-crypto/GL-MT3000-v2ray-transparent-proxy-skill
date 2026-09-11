# 电脑 C 通过 SSH 修复电脑 A 的操作清单

## 已就绪（AI 在电脑 A 上完成）
- 电脑 A 已手动安装 OpenSSH Server，并已在 `192.168.8.192:22` 启动 sshd（监听 `0.0.0.0:22`）。
- 防火墙入站规则 `sshd`（TCP 22 / Allow / Inbound）已放行。
- 电脑 A 当前 IP：WiFi(WLAN) `192.168.8.192`、有线(以太网) `192.168.10.6`。
  - ⚠️ 做「纯 MT3000 WiFi」测试时，请把电脑 A 的**有线网线拔掉**。

## 第 1 步：让电脑 C 连到同一 MT3000 WiFi
电脑 C 必须和电脑 A 在同一个 MT3000 WiFi 下（都拿到 `192.168.8.x` 地址），否则连不进 `192.168.8.192`。

## 第 2 步：在电脑 C 上 SSH 进电脑 A
在电脑 C 打开 PowerShell / 终端，运行：

```
ssh <电脑A的登录用户名>@192.168.8.192
```

- 用户名：电脑 A 开机登录的那个账号（本机 Administrator 就填 `Administrator`；若用微软账户登录则填该邮箱）。
- 密码：电脑 A 该账号的 Windows 登录密码。
- 首次连接会问 `Are you sure you want to continue connecting?` → 输入 `yes` 回车。

连上后命令行提示符会变成电脑 A 的环境（例如 `C:\Users\Administrator>`），说明你已身处电脑 A，后续命令全部作用在**电脑 A** 上。

## 第 3 步：在 SSH 会话里只读诊断电脑 A 的代理残留
（先确认，不改动）

```
netsh winhttp show proxy
Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable,ProxyServer -ErrorAction SilentlyContinue
Get-ChildItem Env: | Where-Object {$_.Name -match 'PROXY'}
[Environment]::GetEnvironmentVariable("HTTP_PROXY","User")
[Environment]::GetEnvironmentVariable("HTTP_PROXY","Machine")
```

> 预期会看到 v2rayN 残留：`ProxyServer=127.0.0.1:10808` 和/或 `HTTP_PROXY/HTTPS_PROXY=127.0.0.1:10808`（死端口）。

## 第 4 步：清理电脑 A 的死代理（核心修复）
在 SSH 会话里粘贴执行：

```
$reg="HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty $reg -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty $reg -Name ProxyServer -Value "" -Type String -ErrorAction SilentlyContinue
[Environment]::SetEnvironmentVariable("HTTP_PROXY",$null,"User")
[Environment]::SetEnvironmentVariable("HTTPS_PROXY",$null,"User")
[Environment]::SetEnvironmentVariable("HTTP_PROXY",$null,"Machine")
[Environment]::SetEnvironmentVariable("HTTPS_PROXY",$null,"Machine")
Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
netsh winhttp show proxy
```

> 验证：最后 `netsh winhttp show proxy` 应输出「直接访问(没有代理服务器)」。

## 第 5 步：彻底重开电脑 A 的 WorkBuddy（必须）
已打开的 WorkBuddy 进程内存里还揣着旧死代理，光清变量不够。

```
taskkill /F /IM WorkBuddy.exe /T
```

然后**在电脑 A 本机**（不是 SSH 会话里）从开始菜单重新打开 WorkBuddy。
- 此时电脑 A 应只连 MT3000 WiFi、v2rayN 已关、无本机代理 → WorkBuddy 走 MT3000 透明代理直接联网，登录几秒通过。

## 说明
- 这套修复只动电脑 A 本机，**不改 MT3000 路由器**（路由器透明代理此前已修好并经电脑 C 验证可用）。
- sshd 是「直接进程」方式拉的（非 Windows 服务），电脑 A 重启后不会自动恢复；如需长期可用，重启后重跑 `C:\Program Files\OpenSSH\sshd.exe -D -p 22` 即可（或后续再排 service 1067 问题）。
