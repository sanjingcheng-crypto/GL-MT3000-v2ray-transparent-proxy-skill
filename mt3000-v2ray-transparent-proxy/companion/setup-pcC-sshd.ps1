# setup-pcC-sshd.ps1
# Install OpenSSH Server on PC C, allow PC A passwordless SSH.
# PURE ASCII VERSION - no Chinese chars, to avoid PowerShell 5.1 encoding breakage.

# 1) Self-elevate to admin if not already
$scriptPath = $PSCommandPath
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ELEVATE] Not admin, requesting UAC..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-File `"$scriptPath`""
    exit
}

$ErrorActionPreference = "Stop"
$OPENSSH_DIR = "C:\Program Files\OpenSSH"
$TMP = $env:TEMP
$PUBKEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICORJmryQ0HnuXa22kzgs7uVFlzG0/sh3VjUZk0qJC/B administrator@LIUSHENG-SRV-B"

Write-Host "[1] Clean old OpenSSH dir"
if (Test-Path $OPENSSH_DIR) { Remove-Item $OPENSSH_DIR -Recurse -Force }
New-Item -ItemType Directory -Path $OPENSSH_DIR -Force | Out-Null

Write-Host "[2] Download OpenSSH-Win64 (latest from GitHub)"
$rel = Invoke-RestMethod "https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest"
$url = ($rel.assets | Where-Object { $_.name -eq 'OpenSSH-Win64.zip' }).browser_download_url
Write-Host ("    url: {0}" -f $url)
Invoke-WebRequest $url -OutFile "$TMP\OpenSSH-Win64.zip"
Expand-Archive "$TMP\OpenSSH-Win64.zip" "$TMP\ossh" -Force
Copy-Item "$TMP\ossh\OpenSSH-Win64\*" $OPENSSH_DIR -Recurse -Force

Write-Host "[3] Generate host keys"
$sshDir = "C:\ProgramData\ssh"
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
Set-Location $OPENSSH_DIR
& .\ssh-keygen.exe -t rsa -b 4096 -f "$sshDir\ssh_host_rsa_key" -N "" -q
& .\ssh-keygen.exe -t ed25519 -f "$sshDir\ssh_host_ed25519_key" -N "" -q
& .\ssh-keygen.exe -t ecdsa -b 521 -f "$sshDir\ssh_host_ecdsa_key" -N "" -q
Get-ChildItem "$sshDir\ssh_host_*_key" | ForEach-Object { icacls $_.FullName /inheritance:r /grant:r "SYSTEM:(R)" /grant:r "Administrators:(R)" | Out-Null }

Write-Host "[4] Write PC A public key (passwordless login)"
$ak = "$sshDir\administrators_authorized_keys"
$PUBKEY.Trim() | Out-File $ak -Encoding ascii -Force
icacls $ak /inheritance:r /grant:r "SYSTEM:(R)" /grant:r "Administrators:(R)" | Out-Null
$userKey = "$env:USERPROFILE\.ssh\authorized_keys"
New-Item -ItemType Directory -Path (Split-Path $userKey) -Force | Out-Null
$PUBKEY.Trim() | Out-File $userKey -Encoding ascii -Force
icacls $userKey /inheritance:r /grant:r "SYSTEM:(R)" /grant:r "Administrators:(R)" /grant:r "$env:USERNAME:(R)" | Out-Null

Write-Host "[5] Configure sshd_config"
$cfg = "$OPENSSH_DIR\sshd_config"
$c = Get-Content $cfg -Raw
if ($c -notmatch "PasswordAuthentication yes") { Add-Content $cfg "`nPasswordAuthentication yes" }
if ($c -notmatch "PermitRootLogin") { Add-Content $cfg "`nPermitRootLogin no" }

Write-Host "[6] Start sshd on port 22 (background)"
Start-Process -FilePath "$OPENSSH_DIR\sshd.exe" -ArgumentList "-D","-p","22" -WindowStyle Hidden

Write-Host "[7] Firewall allow TCP 22 inbound"
if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

Start-Sleep 2
Write-Host "=== RESULT ==="
Write-Host ("PC C login user : {0}" -f $env:USERNAME)
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' } | Select-Object -First 1).IPAddress
Write-Host ("PC C LAN IP     : {0}" -f $ip)
$t = Test-NetConnection -ComputerName 127.0.0.1 -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
Write-Host ("Port 22 open    : {0}" -f $t)
Write-Host ("PC A run: ssh -i C:\Users\Administrator\.ssh\id_ed25519_v2raya {0}@{1}" -f $env:USERNAME, $ip)
