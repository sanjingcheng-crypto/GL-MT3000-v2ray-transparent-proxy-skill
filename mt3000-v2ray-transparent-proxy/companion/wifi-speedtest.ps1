<#
.SYNOPSIS
  WiFi / 有线 网速对比测试 —— 测「当前连接」，结果追加到 CSV
.DESCRIPTION
  在 PC C（或任意 Windows 机）上，对每一条待测网络各跑一次本脚本：
    1) 自动识别当前连接：有线 / WiFi(SSID) / IP / 网关
    2) 国内延迟      : ping 223.5.5.5  x N
    3) 国际延迟      : ping 8.8.8.8    x N  （D1 直连通常不通/超时，MT3000 走代理可见 RTT）
    4) 通用 CDN 吞吐 : 从 Cloudflare 边缘拉 $DlMB MB（5 条路径同源，公平比）
    5) 国内镜像吞吐  : 从阿里云大文件 range 拉前 $DlMB MB（走代理时吞吐会被拖低）
  每次运行追加一行到 wifi-speedtest-results.csv，并即时打印汇总表。
  切换网络后重跑即可 —— 5 条路径各跑一次，最后看 CSV 对比。

  待测 5 条路径（按用户 2026-09-11 确认）：
    A0 有线(接 D1 路由器)   A1 D1-2401(2.4G)   A2 D1-2401-5G(5G)
    B1 GL-MT3000-2D7(2.4G)  B2 GL-MT3000-2D7-5G(5G)

  公平性说明：第 4 项用同一 Cloudflare 端点，5 条路径拉同一份字节，
  吞吐差异纯来自「路径本身」（含 MT3000 双 WiFi 跳 + 透明代理开销），可直接横向比。
#>
param(
  [string]$CsvPath = "$PSScriptRoot\wifi-speedtest-results.csv",
  [int]$PingCount = 15,
  [int]$DlMB = 80,
  # 国内镜像大文件（range 取前 $DlMB MB，验证 range 支持可换源）
  [string]$DomesticUrl = 'https://mirrors.aliyun.com/centos/7.9.2009/isos/x86_64/CentOS-7-x86_64-DVD-2009.iso',
  # 通用 CDN 吞吐端点（按字节返回，跨路径公平）
  [string]$IntlUrl = ''
)

if (-not $IntlUrl) { $IntlUrl = "https://speed.cloudflare.com/__down?bytes=$($DlMB * 1048576)" }

function Get-ConnInfo {
  $conn = Get-NetConnectionProfile | Where-Object {
    $_.IPv4Connectivity -in @('Internet', 'LocalNetwork')
  } | Select-Object -First 1
  $ssidRaw = (netsh wlan show interfaces 2>$null | Select-String '^\s*SSID' | Select-Object -First 1)
  $ssid = if ($ssidRaw) { ($ssidRaw.ToString().Split(':')[-1]).Trim() } else { '' }
  $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $conn.InterfaceIndex -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1).IPAddress
  $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $conn.InterfaceIndex -ErrorAction SilentlyContinue |
         Select-Object -First 1).NextHop
  $type = if ([string]::IsNullOrEmpty($ssid)) { 'Wired' } else { 'WiFi' }
  [PSCustomObject]@{ Type = $type; SSID = $ssid; IP = $ip; Gateway = $gw; Iface = $conn.InterfaceAlias }
}

function Test-PingAvg {
  param([string]$Target, [int]$Count)
  try {
    $r = Test-Connection -ComputerName $Target -Count $Count -ErrorAction Stop
    return [math]::Round(($r.ResponseTime | Measure-Object -Average).Average, 1)
  } catch { return $null }
}

function Test-DownloadMbps {
  param([string]$Url, [bool]$Range, [long]$Bytes)
  $curlArgs = if ($Range) {
    @('-s', '-r', "0-$($Bytes - 1)", '-o', 'NUL', '-w', '%{speed_download}', $Url)
  } else {
    @('-s', '-o', 'NUL', '-w', '%{speed_download}', $Url)
  }
  try {
    $speed = & curl.exe @curlArgs
    if ($speed -match '^[\d.]+$') { return [math]::Round([double]$speed / 1048576, 2) }
    return $null
  } catch { return $null }
}

# ---------- main ----------
$info = Get-ConnInfo
Write-Host ("`n当前连接: {0}   SSID='{1}'   IP={2}   网关={3}" -f $info.Type, $info.SSID, $info.IP, $info.Gateway)

Write-Host ("`n→ 国内延迟  ping 223.5.5.5 x{0} ..." -f $PingCount)
$pingDom = Test-PingAvg -Target '223.5.5.5' -Count $PingCount
Write-Host ("  国内延迟: {0} ms" -f $(if ($pingDom) { $pingDom } else { '超时' }))

Write-Host ("→ 国际延迟  ping 8.8.8.8   x{0} ..." -f $PingCount)
$pingIntl = Test-PingAvg -Target '8.8.8.8' -Count $PingCount
Write-Host ("  国际延迟: {0}" -f $(if ($pingIntl) { "$pingIntl ms" } else { '超时/不通（直连被墙属正常）' }))

$bytes = [long]($DlMB * 1048576)
Write-Host ("`n→ 通用 CDN 吞吐  {0} MB ..." -f $DlMB)
$mbpsCdn = Test-DownloadMbps -Url $IntlUrl -Range $false -Bytes $bytes
Write-Host ("  CDN 吞吐: {0} MB/s" -f $(if ($mbpsCdn) { $mbpsCdn } else { 'FAIL' }))

Write-Host ("→ 国内镜像吞吐  {0} MB (range) ..." -f $DlMB)
$mbpsDom = Test-DownloadMbps -Url $DomesticUrl -Range $true -Bytes $bytes
Write-Host ("  国内镜像吞吐: {0} MB/s" -f $(if ($mbpsDom) { $mbpsDom } else { 'FAIL（源不支持range或不通）' }))

$row = [PSCustomObject]@{
  Time             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Type             = $info.Type
  Path             = if ($info.Type -eq 'WiFi') { $info.SSID } else { 'Wired(有线)' }
  IP               = $info.IP
  Gateway          = $info.Gateway
  PingDomestic_ms  = if ($pingDom) { $pingDom } else { '超时' }
  PingIntl_ms      = if ($pingIntl) { $pingIntl } else { '不通' }
  CDN_DL_MBps      = if ($mbpsCdn) { $mbpsCdn } else { 'FAIL' }
  Domestic_DL_MBps = if ($mbpsDom) { $mbpsDom } else { 'FAIL' }
}
$row | Export-Csv -Path $CsvPath -NoTypeInformation -Append -Encoding UTF8
Write-Host ("`n✅ 已记录一行到: {0}" -f $CsvPath)
Write-Host "`n=== 累计结果汇总 ==="
Import-Csv $CsvPath | Format-Table -AutoSize | Out-String | Write-Host
