<#
  setup-pcC-sshd-v2.ps1   --   ASCII ONLY (PS 5.1 + Chinese locale safe)

  Goal: install OpenSSH Server on PC C, let PC A log in with a key (no password).

  WHAT WAS WRONG IN setup-pcC-sshd.ps1  (all three confirmed by live testing)
  ---------------------------------------------------------------------------
  BUG 1  line 46 used  "$env:USERNAME:(R)"
         PowerShell parses "$env:USERNAME:" as an undefined variable and drops it,
         so icacls received a bare "(R)"   ->   error: invalid parameter "(R)".
         Fixed by using "${env:USERNAME}:(R)"  (verified: prints onroud:(R)).

  BUG 2  line 50 read  C:\Program Files\OpenSSH\sshd_config
         that file does not exist: the release zip only ships "sshd_config_default".
         With $ErrorActionPreference='Stop' the script died here, so step [6]
         (start sshd) and [7] (firewall) never ran -> nothing listened on port 22.
         Fixed: copy sshd_config_default -> sshd_config, then append overrides.

  BUG 3  line 55 started sshd.exe as a plain background process.
         A directly started sshd.exe cannot create a user logon session: it lacks
         SeAssignPrimaryTokenPrivilege / SeTcbPrivilege / SeBackupPrivilege /
         SeRestorePrivilege / SeImpersonatePrivilege and does not run as LocalSystem.
         Result: password/key authentication SUCCEEDS, then the connection is reset
         when the session channel opens (WinError 10054) -- exactly what PC A does.
         Fixed: register sshd as a real Windows service through the official
         install-sshd.ps1 (grants those 5 privileges, runs as LocalSystem),
         set startup to Automatic so it also comes back after a reboot.
  ---------------------------------------------------------------------------
#>

# ---------------- 0. self elevate ----------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ELEVATE] not elevated - asking for UAC, watch for the new window..."
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`""
    exit
}

$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

$SSH_DIR  = 'C:\Program Files\OpenSSH'
$DATA_DIR = Join-Path $env:ProgramData 'ssh'
$PUBKEY   = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICORJmryQ0HnuXa22kzgs7uVFlzG0/sh3VjUZk0qJC/B administrator@LIUSHENG-SRV-B'
$LOG      = 'C:\Jim\ssh_testing\sshd_result.txt'

Remove-Item $LOG -Force -ErrorAction SilentlyContinue
function Say([string]$m) {
    Write-Host $m
    Add-Content -Path $LOG -Value $m -Encoding UTF8 -ErrorAction SilentlyContinue
}

Say "==================================================="
Say " PC C sshd setup v2"
Say (" host    : {0}" -f $env:COMPUTERNAME)
Say (" user    : {0}" -f $env:USERNAME)
Say (" time    : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say "==================================================="

# ---------------- 1. binaries ----------------
Say ""
Say "[1] OpenSSH binaries"
if (Test-Path (Join-Path $SSH_DIR 'sshd.exe')) {
    Say ("    already present : {0}" -f (Get-Item (Join-Path $SSH_DIR 'sshd.exe')).VersionInfo.ProductVersion)
} else {
    Say "    missing - downloading latest OpenSSH-Win64"
    New-Item -ItemType Directory -Path $SSH_DIR -Force | Out-Null
    $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest'
    $url = ($rel.assets | Where-Object { $_.name -eq 'OpenSSH-Win64.zip' }).browser_download_url
    Say ("    url : {0}" -f $url)
    Invoke-WebRequest $url -OutFile "$env:TEMP\OpenSSH-Win64.zip"
    Expand-Archive "$env:TEMP\OpenSSH-Win64.zip" "$env:TEMP\ossh" -Force
    Copy-Item "$env:TEMP\ossh\OpenSSH-Win64\*" $SSH_DIR -Recurse -Force
    Say "    extracted"
}

# ---------------- 2. host keys (keep existing ones) ----------------
Say ""
Say "[2] Host keys"
New-Item -ItemType Directory -Path $DATA_DIR -Force | Out-Null
Push-Location $SSH_DIR
if (-not (Test-Path (Join-Path $DATA_DIR 'ssh_host_rsa_key'))) {
    & .\ssh-keygen.exe -t rsa -b 4096 -f "$DATA_DIR\ssh_host_rsa_key" -N "" -q
    Say "    generated rsa"
} else { Say "    keep ssh_host_rsa_key" }
if (-not (Test-Path (Join-Path $DATA_DIR 'ssh_host_ed25519_key'))) {
    & .\ssh-keygen.exe -t ed25519 -f "$DATA_DIR\ssh_host_ed25519_key" -N "" -q
    Say "    generated ed25519"
} else { Say "    keep ssh_host_ed25519_key" }
if (-not (Test-Path (Join-Path $DATA_DIR 'ssh_host_ecdsa_key'))) {
    & .\ssh-keygen.exe -t ecdsa -b 521 -f "$DATA_DIR\ssh_host_ecdsa_key" -N "" -q
    Say "    generated ecdsa"
} else { Say "    keep ssh_host_ecdsa_key" }
Pop-Location

# ---------------- 3. sshd_config  (BUG 2 fix) ----------------
Say ""
Say "[3] sshd_config (from sshd_config_default)"
$cfgDefault = Join-Path $SSH_DIR 'sshd_config_default'
if (-not (Test-Path $cfgDefault)) { throw "sshd_config_default not found in $SSH_DIR" }
foreach ($p in @( (Join-Path $SSH_DIR 'sshd_config'), (Join-Path $DATA_DIR 'sshd_config') )) {
    Copy-Item $cfgDefault $p -Force
    $c = Get-Content $p -Raw
    $extra = @()
    if ($c -notmatch '(?m)^\s*PubkeyAuthentication\s')   { $extra += 'PubkeyAuthentication yes' }
    if ($c -notmatch '(?m)^\s*PasswordAuthentication\s') { $extra += 'PasswordAuthentication yes' }
    if ($extra.Count -gt 0) {
        Add-Content $p ("`r`n# --- added by setup-pcC-sshd-v2 ---`r`n" + ($extra -join "`r`n"))
    }
    Say ("    written : {0}" -f $p)
}

# ---------------- 4. PC A public key  (BUG 1 fix) ----------------
Say ""
Say "[4] PC A public key"
$ak = Join-Path $DATA_DIR 'administrators_authorized_keys'
$PUBKEY.Trim() | Out-File $ak -Encoding ascii -Force
# NOTE: correct syntax is "${env:USERNAME}:(R)" - the old "$env:USERNAME:(R)" lost the name
icacls $ak /inheritance:r /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
Say ("    {0}" -f $ak)

$uk = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
New-Item -ItemType Directory -Path (Split-Path $uk) -Force | Out-Null
$PUBKEY.Trim() | Out-File $uk -Encoding ascii -Force
icacls $uk /inheritance:r /grant:r "SYSTEM:R" /grant:r "Administrators:R" /grant:r "${env:USERNAME}:F" | Out-Null
Say ("    {0}" -f $uk)

# ---------------- 5. register + start service  (BUG 3 fix) ----------------
Say ""
Say "[5] Register sshd as a Windows service (LocalSystem)"
try {
    & "$SSH_DIR\install-sshd.ps1" -Confirm:$false 2>&1 | ForEach-Object { Say ("    " + $_.ToString()) }
} catch {
    Say ("    install-sshd.ps1 reported: {0}" -f $_.Exception.Message)
}

# make sure the service really exists before touching it
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) {
    Say "    !! service 'sshd' still missing, trying direct registration"
    New-Service -Name sshd -DisplayName 'OpenSSH SSH Server' -BinaryPathName "`"$SSH_DIR\sshd.exe`"" -StartupType Automatic | Out-Null
    sc.exe privs sshd SeAssignPrimaryTokenPrivilege/SeTcbPrivilege/SeBackupPrivilege/SeRestorePrivilege/SeImpersonatePrivilege | Out-Null
}

Set-Service sshd -StartupType Automatic
try {
    Start-Service sshd
    Say "    service started"
} catch {
    Say ("    Start-Service failed: {0}" -f $_.Exception.Message)
}
# restart automatically if it ever crashes
sc.exe failure sshd reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
Say ("    startup type : {0}" -f (Get-Service sshd).StartupType)
Say ("    status       : {0}" -f (Get-Service sshd).Status)

# ---------------- 6. firewall ----------------
Say ""
Say "[6] Firewall TCP 22 inbound"
if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Say "    rule 'sshd' created"
} else {
    Say "    rule 'sshd' already exists"
}

# ---------------- 7. verify ----------------
Say ""
Say "[7] Verify"
Start-Sleep -Seconds 2
$listen = netstat -ano | Select-String ':22\s+.*LISTENING'
if ($listen) { $listen | ForEach-Object { Say ("    " + $_.ToString().Trim()) } } else { Say "    !! nothing listening on 22" }

Say "    --- effective config (which files sshd actually uses) ---"
try {
    $eff = & "$SSH_DIR\sshd.exe" -T 2>&1
    $eff | Select-String -Pattern '^(pubkeyauthentication|passwordauthentication|authorizedkeysfile|permitrootlogin)' | ForEach-Object { Say ("    " + $_.ToString()) }
} catch {
    Say ("    sshd -T failed: {0}" -f $_.Exception.Message)
}

Say "    --- loopback health test (EXPECT 'Permission denied (publickey)' = server healthy) ---"
try {
    $t = & "$SSH_DIR\ssh.exe" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=8 -p 22 "$env:USERNAME@127.0.0.1" "echo OK" 2>&1
    $t | Select-Object -First 6 | ForEach-Object { Say ("    " + $_.ToString()) }
} catch {
    Say ("    loopback test error: {0}" -f $_.Exception.Message)
}
Say "    (a reset/10054 here means session channels are still broken; 'Permission denied' is GOOD)"

# ---------------- summary ----------------
$ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '192.168.8.*' } | Select-Object -First 1).IPAddress
Say ""
Say "==================================================="
Say (" PC C LAN IP : {0}" -f $ip)
Say (" sshd status : {0} (startup {1})" -f (Get-Service sshd).Status, (Get-Service sshd).StartupType)
Say "==================================================="
Say " On PC A run:"
Say ("   ssh -i C:\Users\Administrator\.ssh\id_ed25519_v2raya {0}@{1}" -f $env:USERNAME, $ip)
Say "==================================================="
