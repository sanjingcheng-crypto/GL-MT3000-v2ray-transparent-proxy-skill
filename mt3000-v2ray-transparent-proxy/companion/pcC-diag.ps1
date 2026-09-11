Write-Host "=== PC C hostname ==="
hostname
Write-Host "=== current user ==="
whoami
Write-Host "=== IPv4 addresses ==="
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -ne '127.0.0.1'} | Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize
Write-Host "=== default route ==="
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceAlias, NextHop, RouteMetric | Format-Table -AutoSize
Write-Host "=== saved WiFi profiles ==="
netsh wlan show profiles | Select-String ' : '
Write-Host "=== WiFi / Ethernet adapters ==="
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed | Format-Table -AutoSize
Write-Host "=== can PC C reach D1 gateway? (arp) ==="
arp -a | Select-String '192.168' | ForEach-Object { $_.Line.Trim() }
Write-Host "=== curl / test tools present? ==="
$null = Get-Command curl.exe -ErrorAction SilentlyContinue; if (Get-Command curl.exe -ErrorAction SilentlyContinue) { Write-Host "curl.exe: present" } else { Write-Host "curl.exe: MISSING" }
if (Get-Command iperf3.exe -ErrorAction SilentlyContinue) { Write-Host "iperf3: present" } else { Write-Host "iperf3: missing" }
