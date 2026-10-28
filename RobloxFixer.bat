@echo off
title Roblox Fixer - error 277 and missing icons
echo ==================================================
echo   ROBLOX FIXER
echo   Removes zapret/DPI tools + fixes error 277
echo   and missing icons (broken DNS)
echo ==================================================
echo.
echo This needs Administrator rights.
echo If a UAC prompt appears, click YES.
echo.
echo Close Roblox before continuing.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content -Raw '%~f0';$m='#__PS1_START__';$p=$c.LastIndexOf($m);$ps=$c.Substring($p+$m.Length);$f=Join-Path $env:TEMP 'RobloxFixer.ps1';[IO.File]::WriteAllText($f,$ps,[Text.Encoding]::UTF8);& powershell -NoProfile -ExecutionPolicy Bypass -File $f"
echo.
pause
goto :eof
#__PS1_START__
# ===================== RobloxFixer.ps1 =====================
# Self-contained fixer for Roblox error 277 + missing icons.
# Works on any PC: auto-detects paths, adapters and services.
$ErrorActionPreference = 'SilentlyContinue'
function Log($m, $c){ if($c){ Write-Host $m -ForegroundColor $c } else { Write-Host $m } }

Log ""
Log "=================================================" Cyan
Log "  ROBLOX FIXER"
Log "=================================================" Cyan

# ---------- admin check ----------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole( `
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){
    Log "ERROR: not running as Administrator." Red
    Log "Right-click the file -> Run as administrator."
    Read-Host "Press Enter to exit"; exit 1
}

# ---------- warn if Roblox running ----------
$rb = Get-Process RobloxPlayerBeta,Windows10Universal,RobloxStudioBeta -EA SilentlyContinue
if($rb){
    Log "WARNING: Roblox is running. Close it for a clean fix." Yellow
    Log ""
}

# =========================================================
# 1. Find and remove ANY service that launches winws/zapret/WinDivert
# =========================================================
Log "[1/7] Scanning for zapret / DPI services..."
$svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$foundSvc = 0
Get-ChildItem $svcRoot -EA SilentlyContinue | ForEach-Object {
    $img = (Get-ItemProperty $_.PSPath -EA SilentlyContinue).ImagePath
    if($img -match 'winws|zapret|WinDivert'){
        $name = $_.PSChildName
        Log "  Found: $name" Yellow
        & sc.exe stop $name  | Out-Null
        Start-Sleep -Milliseconds 400
        & sc.exe delete $name | Out-Null
        Log "  Removed service: $name" Green
        $foundSvc++
    }
}
if($foundSvc -eq 0){ Log "  No zapret/DPI services found." }
Log ""

# =========================================================
# 2. Kill interceptor processes + disable known proxy services
# =========================================================
Log "[2/7] Stopping interceptor processes..."
$procs = @('winws','happd','BestProxyVPN','exitlag','mudfish','goodbyedpi','zapret','vpngame')
foreach($p in $procs){
    if(Get-Process -Name $p -EA SilentlyContinue){
        Stop-Process -Name $p -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 300
        Stop-Process -Name $p -Force -EA SilentlyContinue
        Log "  Killed: $p" Green
    }
}
# disable common VPN/DPI services so they stay gone
foreach($s in @('HappService','RvControlSvc')){
    Stop-Service $s -Force -EA SilentlyContinue
    & sc.exe config $s start= disabled | Out-Null
}
# unload WinDivert driver if still present anywhere
Get-CimInstance Win32_SystemDriver -EA SilentlyContinue |
    Where-Object { $_.Name -match 'WinDivert' -or $_.PathName -match 'WinDivert' } | ForEach-Object {
        & sc.exe stop $_.Name | Out-Null
        & sc.exe config $_.Name start= disabled | Out-Null
        Log "  Disabled driver: $($_.Name)" Green
    }
Log ""

# =========================================================
# 3. Remove leftover / broken proxy settings
# =========================================================
Log "[3/7] Cleaning proxy settings..."
$inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Remove-ItemProperty -Path $inet -Name ProxyServer -EA SilentlyContinue
Remove-ItemProperty -Path $inet -Name ProxyEnable  -EA SilentlyContinue
Set-ItemProperty   -Path $inet -Name ProxyEnable -Value 0 -Type DWord -EA SilentlyContinue
Log "  Done."
Log ""

# =========================================================
# 4. Clear Roblox cache
# =========================================================
Log "[4/7] Clearing Roblox cache..."
$rbx = Join-Path $env:LOCALAPPDATA 'Roblox'
foreach($sub in @('Cache','http_cache')){
    $p = Join-Path $rbx $sub
    if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA SilentlyContinue; Log "  Cleared: $sub" }
}
Log "  Done."
Log ""

# =========================================================
# 5. Set fast DoH DNS on the real network adapter
# =========================================================
Log "[5/7] Configuring DNS-over-HTTPS (Cloudflare 1.1.1.1)..."
$adapter = Get-NetAdapter -EA SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'VPN|Virtual|TAP|TUN|Wintun|Radmin|Loopback' } |
    Sort-Object -Property @{Expression={ if($_.InterfaceDescription -match 'Wireless|Wi-Fi|Wi-Fi|Ethernet') {0} else {1} }} |
    Select-Object -First 1
if($adapter){
    Log "  Adapter: $($adapter.Name)"
    if(Get-Command Set-DnsClientDohServerAddress -EA SilentlyContinue){
        foreach($ip in @('1.1.1.1','1.0.0.1')){
            Set-DnsClientDohServerAddress -ServerAddress $ip `
                -DohTemplate 'https://cloudflare-dns.com/dns-query' `
                -AllowFallbackToUdp $false -AutoUpgrade $true -EA SilentlyContinue
        }
        Log "  DoH templates registered."
    }
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @('1.1.1.1','1.0.0.1') -EA SilentlyContinue
    Log "  DNS set to 1.1.1.1 / 1.0.0.1." Green
}else{
    Log "  No active adapter found, skipping DNS." Yellow
}
Log ""

# =========================================================
# 6. Fix the icon CDN: if tr.rbxcdn.com does not resolve,
#    get a working IP via DoH, verify it, write to hosts.
# =========================================================
Log "[6/7] Fixing icon CDN (tr.rbxcdn.com)..."
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$thumbPath = '/30DAY-AvatarHeadshot-C73A8E3FFC598B21EF57CC4E694596D1-Png/150/150/AvatarHeadshot/Webp/noFilter'

# does it already resolve?
$cur = Resolve-DnsName tr.rbxcdn.com -Type A -EA SilentlyContinue | Where-Object { $_.IPAddress }
if($cur){
    Log "  tr.rbxcdn.com already resolves -> $((($cur.IPAddress) | Select-Object -First 1)). Skipping hosts." Green
} else {
    Log "  tr.rbxcdn.com does NOT resolve -> applying hosts workaround." Yellow
    $candidates = @()
    foreach($doh in @('https://cloudflare-dns.com/dns-query','https://1.1.1.1/dns-query','https://dns.google/resolve')){
        try{
            $r = Invoke-RestMethod -Uri "$doh`?name=tr.rbxcdn.com&type=A" -Headers @{Accept='application/dns-json'} -TimeoutSec 10 -EA Stop
            $candidates += ($r.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
        }catch{}
    }
    $candidates = $candidates | Where-Object { $_ } | Select-Object -Unique
    Log "  Candidate IPs: $($candidates -join ', ')"
    $goodIP = $null
    foreach($ip in $candidates){
        $code = curl.exe -4 -s -o NUL -w "%{http_code}" --max-time 10 --resolve "tr.rbxcdn.com:443:$ip" -A "Mozilla/5.0" -H "Referer: https://www.roblox.com/" "https://tr.rbxcdn.com$thumbPath"
        if($code -eq '200'){ $goodIP = $ip; Log "  Verified $ip -> HTTP 200 (works!)" Green; break }
        else { Log "  $ip -> HTTP $code (skip)" }
    }
    if($goodIP){
        $lines = Get-Content $hostsPath -EA SilentlyContinue | Where-Object { $_ -notmatch 'tr\.rbxcdn\.com' }
        $lines += "$goodIP  tr.rbxcdn.com"
        Set-Content -Path $hostsPath -Value $lines -Encoding ASCII -Force -EA SilentlyContinue
        Log "  hosts updated: $goodIP  tr.rbxcdn.com" Green
    } else {
        Log "  Could not verify an IP; hosts not changed." Yellow
        Log "  (A reboot usually fixes resolution.)" Yellow
    }
}
Log ""

# =========================================================
# 7. Flush DNS + reset Winsock + verify
# =========================================================
Log "[7/7] Flushing DNS and resetting Winsock..."
ipconfig /flushdns | Out-Null
netsh winsock reset | Out-Null
Log "  Done."
Log ""

# ---------- VERIFICATION ----------
Log "=================================================" Cyan
Log "  RESULT"
Log "=================================================" Cyan

$okAll = $true

# interceptors gone?
$alive = Get-Process -Name $procs -EA SilentlyContinue
if($alive){ Log "  [FAIL] Interceptors still running: $($alive.Name -join ', ')" Red; $okAll=$false }
else { Log "  [OK] All interceptor processes stopped" Green }

# zapret service gone?
$zsrv = Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object { $_.PathName -match 'winws|zapret' }
if($zsrv){ Log "  [FAIL] zapret service still present: $($zsrv.Name)" Red; $okAll=$false }
else { Log "  [OK] No zapret/winws service" Green }

# WinDivert gone?
$wd = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | Where-Object { $_.State -eq 'Running' -and $_.Name -match 'WinDivert' }
if($wd){ Log "  [FAIL] WinDivert driver still running" Red; $okAll=$false }
else { Log "  [OK] WinDivert driver not active" Green }

# icon CDN resolves?
$res = Resolve-DnsName tr.rbxcdn.com -Type A -EA SilentlyContinue | Where-Object { $_.IPAddress }
if($res){ Log "  [OK] tr.rbxcdn.com resolves -> icons will load" Green }
else { Log "  [WARN] tr.rbxcdn.com still not resolving" Yellow; $okAll=$false }

Log ""
if($okAll){
    Log "=================================================" Green
    Log "  DONE. All good."
    Log "  1. Restart your PC (finishes the cleanup)."
    Log "  2. Start Roblox - error 277 should be gone."
    Log "=================================================" Green
} else {
    Log "=================================================" Yellow
    Log "  DONE with warnings. Restart your PC, then"
    Log "  run this file again to re-check."
    Log "=================================================" Yellow
}
Log ""
Log "NOTE: do NOT run service.bat / general.bat from a"
Log "zapret folder while playing Roblox - they reinstall"
Log "the service and error 277 comes back."
Log ""
