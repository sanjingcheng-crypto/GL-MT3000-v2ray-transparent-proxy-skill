# fix-pcC-proxy.ps1
# ============================================================
# 用途：修复"电脑 C 连 MT3000 WiFi、无代理软件，但 WorkBuddy 不能联网"的问题。
# 根因：本机环境变量 HTTP_PROXY / HTTPS_PROXY 指向死端口 127.0.0.1:7890
#       （之前 Clash/v2rayN 残留，代理软件已关 → 端口已死）。
#       WorkBuddy 是 Electron/Node 应用，会读这两个变量 → 请求发往死端口 → 无网络；
#       Chrome 不读 env 代理、走系统直连经 MT3000 透明代理 → 正常。
#
# ⚠️ 只在【目标电脑 C】上以管理员运行本脚本！
#    不要在运行 WorkBuddy AI 的电脑 A 上运行（除非电脑 A 正是要修的机器）。
# ============================================================

$ErrorActionPreference = "SilentlyContinue"

Write-Host "[1/4] 删除用户级 + 系统级 HTTP(S)_PROXY 环境变量（死代理根因）..." -ForegroundColor Cyan
[Environment]::SetEnvironmentVariable("HTTP_PROXY",  $null, "User")
[Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")
[Environment]::SetEnvironmentVariable("HTTP_PROXY",  $null, "Machine")
[Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "Machine")

Write-Host "[2/4] 清理注册表残留系统代理服务器地址..." -ForegroundColor Cyan
$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty $reg -Name ProxyServer -Value "" -Type String
Set-ItemProperty $reg -Name ProxyEnable -Value 0  -Type DWord

Write-Host "[3/4] 清理当前会话内存残留（仅影响本次验证）..." -ForegroundColor Cyan
Remove-Item Env:HTTP_PROXY  -ErrorAction SilentlyContinue
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue

Write-Host "[4/4] 验证结果：" -ForegroundColor Cyan
Write-Host ("  HTTP_PROXY=[{0}]  HTTPS_PROXY=[{1}]" -f $env:HTTP_PROXY, $env:HTTPS_PROXY)
netsh winhttp show proxy

Write-Host ""
Write-Host "✅ 环境变量已清理完成。" -ForegroundColor Green
Write-Host "⚠️ 重要：请现在【从开始菜单重新启动 WorkBuddy】使改动生效。" -ForegroundColor Yellow
Write-Host "   已打开的 WorkBuddy 进程仍持有旧代理变量，必须重开；最稳妥是注销重登再开。" -ForegroundColor Yellow
Write-Host "   重启后 WorkBuddy 走 MT3000 透明代理即可正常联网。" -ForegroundColor Green
