@echo off
title Roblox Fixer - fix + diagnose
:: Self-elevate once so FIX and DIAGNOSE both run cleanly from this single file
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights - click YES in the UAC prompt...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo ==================================================
echo   ROBLOX FIXER  (running as admin)
echo   [1] FIX      - zapret/277 + icons + DNS + MTU + firewall
echo   [2] DIAGNOSE - live network check for disconnects
echo ==================================================
echo.
echo Close Roblox before running FIX.
echo.
choice /c 12 /n /m "Choose 1 (fix) or 2 (diagnose): "
if errorlevel 2 goto :diagnose
if errorlevel 1 goto :fix
goto :eof

:fix
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content -Raw '%~f0';$m1='#__FIX_MARKER__';$m2='#__DOC_MARKER__';$fi=$c.LastIndexOf($m1);$di=$c.LastIndexOf($m2);$ps=$c.Substring($fi+$m1.Length,$di-$fi-$m1.Length);$f=Join-Path $env:TEMP 'RobloxFixer.ps1';[IO.File]::WriteAllText($f,$ps,[Text.Encoding]::UTF8);& powershell -NoProfile -ExecutionPolicy Bypass -File $f"
echo.
pause
goto :eof

:diagnose
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content -Raw '%~f0';$m2='#__DOC_MARKER__';$di=$c.LastIndexOf($m2);$ps=$c.Substring($di+$m2.Length);$f=Join-Path $env:TEMP 'RobloxNetDoctor.ps1';[IO.File]::WriteAllText($f,$ps,[Text.Encoding]::UTF8);& powershell -NoProfile -ExecutionPolicy Bypass -File $f"
echo.
pause
goto :eof

#__FIX_MARKER__# ===================== RobloxFixer.ps1 =====================
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
function Log($m, $c){ if($c){ Write-Host $m -ForegroundColor $c } else { Write-Host $m } }

Log "=================================================" Cyan
Log "  ROBLOX FIXER"
Log "=================================================" Cyan

# admin check
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole( `
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){
    Log "ERROR: not running as Administrator." Red
    Read-Host "Press Enter to exit"; exit 1
}

# Warn if Roblox running
$rb = Get-Process RobloxPlayerBeta,Windows10Universal,RobloxStudioBeta -EA SilentlyContinue
if($rb){ Log "WARNING: Roblox is running. Close it for a clean fix." Yellow; Log "" }

# 1. Scan + remove zapret/DPI services
Log "[1/9] Scanning for zapret / DPI services (fast)..."
# single WMI query instead of ~500 registry reads -> much faster
$foundSvc = 0
Get-CimInstance Win32_Service -EA SilentlyContinue |
    Where-Object { $_.PathName -match 'winws|zapret|WinDivert' } | ForEach-Object {
        $name = $_.Name
        Log "  Found: $name" Yellow
        & sc.exe stop $name  | Out-Null
        Start-Sleep -Milliseconds 400
        & sc.exe delete $name | Out-Null
        Log "  Removed service: $name" Green
        $foundSvc++
    }
if($foundSvc -eq 0){ Log "  No zapret/DPI services found." }
Log ""

# 2. Kill interceptors + disable proxy services (backed up)
Log "[2/9] Stopping interceptor processes..."
$procs = @('winws','happd','BestProxyVPN','exitlag','mudfish','goodbyedpi','zapret','vpngame')
foreach($p in $procs){
    if(Get-Process -Name $p -EA SilentlyContinue){
        Stop-Process -Name $p -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 300
        Stop-Process -Name $p -Force -EA SilentlyContinue
        Log "  Killed: $p" Green
    }
}
$svcStateBak = @()
foreach($s in @('HappService','RvControlSvc')){
    $cur = Get-CimInstance Win32_Service -Filter "Name='$s'" -EA SilentlyContinue
    if($cur){
        $svcStateBak += [pscustomobject]@{ Name=$s; Start=$cur.StartMode }
        ($svcStateBak | ConvertTo-Json) | Set-Content (Join-Path $env:LOCALAPPDATA 'RobloxFixer\services.backup.json') -Encoding UTF8 -EA SilentlyContinue
    }
    Stop-Service $s -Force -EA SilentlyContinue
    & sc.exe config $s start= disabled | Out-Null
}
Get-CimInstance Win32_SystemDriver -EA SilentlyContinue |
    Where-Object { $_.Name -match 'WinDivert' -or $_.PathName -match 'WinDivert' } | ForEach-Object {
        & sc.exe stop $_.Name | Out-Null
        & sc.exe config $_.Name start= disabled | Out-Null
        Log "  Disabled driver: $($_.Name)" Green
    }
Log ""

# 3. Clean proxy settings
Log "[3/9] Cleaning proxy settings..."
$inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Remove-ItemProperty -Path $inet -Name ProxyServer -EA SilentlyContinue
Remove-ItemProperty -Path $inet -Name ProxyEnable  -EA SilentlyContinue
Set-ItemProperty   -Path $inet -Name ProxyEnable -Value 0 -Type DWord -EA SilentlyContinue
Log "  Done."
Log ""

# 4. Clear Roblox cache
Log "[4/9] Clearing Roblox cache..."
$rbx = Join-Path $env:LOCALAPPDATA 'Roblox'
foreach($sub in @('Cache','http_cache','BrowserCache','Temporary Internet Files')){
    $p = Join-Path $rbx $sub
    if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA SilentlyContinue; Log "  Cleared: $sub" }
}
Log "  Done."
Log ""

# 5. Set DoH DNS
Log "[5/9] Configuring DNS-over-HTTPS (Cloudflare 1.1.1.1)..."
$adapter = Get-NetAdapter -EA SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'VPN|Virtual|TAP|TUN|Wintun|Radmin|Loopback' } |
    Sort-Object -Property @{Expression={ if($_.InterfaceDescription -match 'Wireless|Wi-Fi|Ethernet') {0} else {1} }} |
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
    } else {
        Log "  DoH not supported on this Windows build -> using plain DNS 1.1.1.1 (no encryption)." Yellow
    }
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @('1.1.1.1','1.0.0.1') -EA SilentlyContinue
    Log "  DNS set to 1.1.1.1 / 1.0.0.1." Green
}else{
    Log "  No active adapter found, skipping DNS." Yellow
}
Log ""

# 6. Fix Roblox DNS: pin critical domains (port 53 gets cut mid-game)
Log "[6/9] Fixing Roblox DNS (icons + API + connection)..."
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$thumbPath = '/30DAY-AvatarHeadshot-C73A8E3FFC598B21EF57CC4E694596D1-Png/150/150/AvatarHeadshot/Webp/noFilter'

$bakDir = Join-Path $env:LOCALAPPDATA 'RobloxFixer'
if(-not (Test-Path $bakDir)){ New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
Copy-Item $hostsPath (Join-Path $bakDir 'hosts.backup') -Force -EA SilentlyContinue
Log "  Backup saved: $bakDir\hosts.backup" Green

Clear-DnsClientCache -EA SilentlyContinue
ipconfig /flushdns | Out-Null

# Req200 only for the icon CDN (must return a real image); the rest only need a live TLS endpoint.
$targets = @(
    @{ Host='tr.rbxcdn.com';             Req200=$true;  Path=$thumbPath },
    @{ Host='www.roblox.com';            Req200=$false; Path='/' },
    @{ Host='apis.roblox.com';           Req200=$false; Path='/' },
    @{ Host='ecsv2.roblox.com';          Req200=$false; Path='/' },
    @{ Host='lms.roblox.com';            Req200=$false; Path='/' },
    @{ Host='assetdelivery.roblox.com';  Req200=$false; Path='/' },
    @{ Host='clientsettings.roblox.com'; Req200=$false; Path='/' }
)
$dohList = @('https://dns.google/resolve','https://cloudflare-dns.com/dns-query','https://1.1.1.1/dns-query','https://dns.quad9.net/dns-query')

$verified = @()
foreach($t in $targets){
    $h = $t.Host
    $cands = @()
    $sys = Resolve-DnsName $h -Type A -EA SilentlyContinue | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }
    if($sys){ $cands += $sys }
    foreach($doh in $dohList){
        try{
            $r = Invoke-RestMethod -Uri "$doh`?name=$h&type=A" -Headers @{Accept='application/dns-json'} -TimeoutSec 6 -EA Stop
            $cands += ($r.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
        }catch{}
    }
    $cands = $cands | Where-Object { $_ } | Select-Object -Unique
    $goodIP = $null
    foreach($ip in $cands){
        $code = curl.exe -4 -s -o NUL -w "%{http_code}" --max-time 8 --resolve "${h}:443:${ip}" -A "Mozilla/5.0" -H "Referer: https://www.roblox.com/" "https://$h$($t.Path)"
        if($t.Req200){ if($code -eq '200'){ $goodIP = $ip; break } }
        else { if($code -and $code -ne '000'){ $goodIP = $ip; break } }
    }
    if($goodIP){
        $verified += "$goodIP  $h"
        Log ("  [OK]   {0,-26} -> {1}" -f $h, $goodIP) Green
    } else {
        Log ("  [SKIP] {0,-26} -> no verified IP (left as-is)" -f $h) Yellow
    }
}

if($verified.Count -gt 0){
    $lines = Get-Content $hostsPath -EA SilentlyContinue | Where-Object { $_ -notmatch 'roblox\.com|rbxcdn\.com' }
    $lines += ''
    $lines += '# RobloxFixer: pinned Roblox DNS (icons + API + connection)'
    $lines += $verified
    Set-Content -Path $hostsPath -Value $lines -Encoding ASCII -Force -EA SilentlyContinue
    Log "  hosts updated: $($verified.Count) domain(s) pinned." Green
    Log "  Keeps Roblox online even if port-53 DNS is cut mid-game." Green
} else {
    Log "  Could not verify any IP; hosts not changed." Yellow
    Log "  (A reboot usually fixes resolution.)" Yellow
}
Log ""

# 7. Optimize MTU (fixes AckTimeout / UDP disconnects on PPPoE/VPN/Wi-Fi)
Log "[7/9] Optimizing MTU..."
if($adapter){
    $adName = $adapter.Name
    $bestPayload = 1200
    foreach($sz in @(1472,1464,1452,1440,1424,1400,1372,1340,1300,1272,1200)){
        $o = ping -n 1 -f -l $sz -w 1500 1.1.1.1 2>&1
        if($o -match 'TTL='){ $bestPayload = $sz; break }
    }
    $newMtu = [int]$bestPayload + 28
    $curMtu = (Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -EA SilentlyContinue).NlMtu
    if($newMtu -lt 1500 -and $curMtu -gt $newMtu){
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -NlMtu $newMtu -EA SilentlyContinue
        netsh interface ipv4 set subinterface $adName mtu=$newMtu store=persistent | Out-Null
        Log ("  Path MTU is limited -> set adapter MTU to " + $newMtu + " (was " + $curMtu + ")") Green
        Log "  This fixes AckTimeout / mid-game disconnects." Green
    } else {
        Log ("  MTU already OK (" + $curMtu + "), no change.")
    }
}else{
    Log "  No adapter found, skipping MTU." Yellow
}
Log ""

# 8. Repair Windows Firewall rules for Roblox (fixes 'Cannot contact server')
Log "[8/9] Checking Windows Firewall rules for Roblox..."
$rbxExe = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Roblox\Versions') -Filter 'RobloxPlayerBeta.exe' -Recurse -EA SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if($rbxExe){
    foreach($proto in @('TCP','UDP')){
        $dn = "Roblox Fixer - $proto"
        $rule = Get-NetFirewallRule -DisplayName $dn -EA SilentlyContinue
        if(-not $rule){
            New-NetFirewallRule -DisplayName $dn -Direction Inbound -Program $rbxExe -Protocol $proto -Action Allow -Profile Any -EA SilentlyContinue | Out-Null
            Log "  Added allow rule: $dn" Green
        } else {
            $rule | Enable-NetFirewallRule -EA SilentlyContinue
            Log "  Rule present and enabled: $dn" Green
        }
    }
}else{
    Log "  RobloxPlayerBeta.exe not found - skipping firewall." Yellow
}
Log ""

# 9. Flush DNS + reset Winsock + verify
Log "[9/9] Flushing DNS and resetting Winsock..."
$catBak = Join-Path $env:LOCALAPPDATA 'RobloxFixer\winsock.backup.txt'
netsh winsock show catalog > $catBak 2>$null
Log "  Winsock catalog backed up to $catBak" Green
ipconfig /flushdns | Out-Null
netsh winsock reset | Out-Null
Log "  Done."
Log ""

# VERIFICATION
Log "=================================================" Cyan
Log "  RESULT"
Log "=================================================" Cyan

$okAll = $true

$alive = Get-Process -Name $procs -EA SilentlyContinue
if($alive){ Log "  [FAIL] Interceptors still running: $($alive.Name -join ', ')" Red; $okAll=$false }
else { Log "  [OK] All interceptor processes stopped" Green }

$zsrv = Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object { $_.PathName -match 'winws|zapret' }
if($zsrv){ Log "  [FAIL] zapret service still present: $($zsrv.Name)" Red; $okAll=$false }
else { Log "  [OK] No zapret/winws service" Green }

$wd = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | Where-Object { $_.State -eq 'Running' -and $_.Name -match 'WinDivert' }
if($wd){ Log "  [FAIL] WinDivert driver still running" Red; $okAll=$false }
else { Log "  [OK] WinDivert driver not active" Green }

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
Log "ROLLBACK (if you want to undo):"
Log "  hosts backup     : $bakDir\hosts.backup"
Log "  services backup  : $bakDir\services.backup.json"
Log "  winsock catalog  : $bakDir\winsock.backup.txt"
Log "  To restore hosts : copy hosts.backup over"
Log "    C:\Windows\System32\drivers\etc\hosts"
Log ""
#__DOC_MARKER__
# ===================== RobloxNetDoctor.ps1 =====================
# Live network diagnostics for Roblox disconnects / error 277.
# Run the .bat (as admin), join the broken server, get kicked,
# press a key - it finds the game server IP from the log and tests it.
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Log($m, $c){
    if($c){ Write-Host $m -ForegroundColor $c } else { Write-Host $m }
}

# ---------- admin check ----------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole( `
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){
    Log "ERROR: run as Administrator." Red
    Read-Host "Press Enter to exit"; exit 1
}

# =========================================================
# PHASE 1 - baseline before joining
# =========================================================
Log ""
Log "==================== PHASE 1: BASELINE ====================" Cyan
Log "Checking your system BEFORE you join the server..."
Log ""

$bad = Get-Process -Name 'winws','happd','BestProxyVPN','exitlag','mudfish' -EA SilentlyContinue
if($bad){ Log ("  [FAIL] DPI/proxy running: " + (($bad.Name) -join ', ') + "  -> will break UDP") Red }
else { Log "  [OK] No DPI/proxy interceptors" Green }

$svc = Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object { $_.PathName -match 'winws|zapret' }
if($svc){ Log "  [FAIL] zapret service present -> run RobloxFixer.bat first" Red }
else { Log "  [OK] No zapret/winws service" Green }

$drv = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue |
        Where-Object { $_.State -eq 'Running' -and $_.Name -match 'WinDivert' }
if($drv){ Log "  [FAIL] WinDivert driver running" Red }
else { Log "  [OK] WinDivert not active" Green }

# adapter + signal
$ad = Get-NetAdapter -EA SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'VPN|Virtual|TAP|TUN|Wintun|Radmin|Loopback' } |
    Select-Object -First 1
$adName = ''
if($ad){
    $adName = $ad.Name
    Log ("  [INFO] Adapter: " + $ad.Name + " - " + $ad.InterfaceDescription) Yellow
    if($ad.InterfaceDescription -match 'Wireless|Wi-Fi'){
        $sig = netsh wlan show interfaces | Select-String 'Signal'
        if($sig){ Log ("  [INFO] Wi-Fi signal: " + (($sig.Line -split ':')[-1].Trim())) Yellow }
        Log "  [WARN] On Wi-Fi - UDP drops more likely. LAN cable recommended." Yellow
    }
    $st = Get-NetAdapterStatistics -Name $ad.Name -EA SilentlyContinue
    if($st -and ($st.ReceivedPacketErrors -gt 0 -or $st.ReceivedDiscardedPackets -gt 0)){
        Log ("  [WARN] Adapter errors: RXerr=" + $st.ReceivedPacketErrors + " disc=" + $st.ReceivedDiscardedPackets) Yellow
    }
} else { Log "  [WARN] No active adapter detected" Yellow }

# MTU baseline
Log ""
Log "--- MTU baseline test (1.1.1.1) ---"
foreach($sz in @(1472,1400,1372,1200)){
    $o = ping -n 1 -f -l $sz -w 2000 1.1.1.1 2>&1
    if($o -match 'TTL='){ Log ("  MTU " + $sz + " : OK"); break }
    elseif($o -match 'fragment'){ Log ("  MTU " + $sz + " : fragmentation") Yellow; break }
}
Log ""

# =========================================================
# PHASE 2 - user joins the broken server
# =========================================================
$logDir = Join-Path $env:LOCALAPPDATA 'Roblox\logs'

Log "==================== PHASE 2: JOIN TEST ====================" Cyan
Log "NOW:"
Log "  1. Open Roblox"
Log "  2. Join the server that kicks you"
Log "  3. Wait until you get disconnected"
Log "  4. Come back here and press any key"
Log ""
Read-Host "Press any key when you have been kicked"
Log ""
Log "Analyzing what happened..." Yellow
Log ""

# =========================================================
# PHASE 3 - analyze the newest log
# =========================================================
Log "==================== PHASE 3: ANALYSIS ====================" Cyan

$log = Get-ChildItem $logDir -File -EA SilentlyContinue |
        Where-Object { $_.Name -match 'Player' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

if(-not $log){
    Log "  [FAIL] No Roblox log found. Is Roblox installed?" Red
    Read-Host "Press Enter"; exit 1
}
Log ("  Log: " + $log.Name + "  (" + $log.LastWriteTime + ")")
Log ""

$content = Get-Content $log.FullName -EA SilentlyContinue

$joinM  = $content | Select-String -Pattern 'Server Address\s*=\s*([\d\.]+),\s*Port\s*=\s*(\d+)' | Select-Object -Last 1
$accM   = $content | Select-String -Pattern 'Connection accepted from ([\d\.]+)\|(\d+)' | Select-Object -Last 1
$lostM  = $content | Select-String -Pattern 'Lost connection to ([\d\.]+)\|(\d+): (ID_\w+)' | Select-Object -Last 1
$reason = $content | Select-String -Pattern 'Connection lost: (AckTimeout|Cannot contact|\S*[Tt]imedout|timeout)' | Select-Object -Last 3

$gameIp = $null
$gamePort = $null
if($joinM){
    $gameIp   = $joinM.Matches[0].Groups[1].Value
    $gamePort = $joinM.Matches[0].Groups[2].Value
    Log ("  Target server : " + $gameIp + ":" + $gamePort) Yellow
} else {
    Log "  [WARN] No server address found in log." Yellow
}

if($accM){
    Log ("  Connection accepted: YES (" + $accM.Matches[0].Groups[1].Value + ")  -> you DID join") Green
} else {
    Log "  Connection accepted: NOT FOUND  -> join itself failed" Red
}

if($lostM){ Log ("  Disconnect: " + $lostM.Matches[0].Groups[3].Value) Red }
if($reason){
    Log "  Reason detail:" Yellow
    foreach($r in $reason){
        $t = $r.Line
        $idx = $t.IndexOf('Connection lost')
        if($idx -ge 0){ $t = $t.Substring($idx) }
        Log ("    " + $t)
    }
}
Log ""

# failure signature
$isDns  = [bool]($content | Select-String -Pattern 'Could not resolve host|HttpError: DnsResolve' | Select-Object -Last 1)
$is277  = [bool]($content | Select-String -Pattern '\b277\b' | Select-Object -Last 1)
$isAck  = [bool]($reason | Where-Object { $_.Line -match 'AckTimeout' })
$noConn = [bool]($reason | Where-Object { $_.Line -match 'Cannot contact' })
$isAttemptFail = [bool]($content | Select-String -Pattern 'ID_CONNECTION_ATTEMPT_FAILED' | Select-Object -Last 1)

# which Roblox domains failed DNS (port-53 cut hits many subdomains, not just the CDN)
$failedDomains = $content |
    Select-String -Pattern 'Could not resolve host:\s*([\w\.\-]+)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } |
    Sort-Object -Unique
# connection/API domains -> these cause the "no internet connection" symptom + crash/kick
$connDomains = $failedDomains | Where-Object { $_ -match '^(apis|ecsv2|lms|assetdelivery|clientsettings|auth)\.' }

Log "--- Failure signature ---" Cyan
if($isDns){
    Log "  [DNS] 'Could not resolve host' -> run RobloxFixer.bat (hosts + DoH)" Red
    if($failedDomains){ Log ("        domains that failed: " + ($failedDomains -join ', ')) Yellow }
    if($connDomains){
        Log "  [DNS-CRIT] connection/API domains failed -> this is WHY Roblox says" Red
        Log "             'no internet connection' and kicks / crashes." Red
    }
}
if($isAck){ Log "  [UDP] AckTimeout: your packets go out, server ACKs never return" Red }
if($noConn){ Log "  [UDP] Cannot contact server: game port unreachable" Red }
if($isAttemptFail){ Log "  [UDP] ID_CONNECTION_ATTEMPT_FAILED: could not reach game server" Red }
if($is277){ Log "  [277] Error 277 present in log" Red }
if(-not ($isDns -or $isAck -or $noConn -or $is277 -or $isAttemptFail)){
    Log "  [INFO] No classic failure pattern - see raw tail below" Yellow
}
Log ""

# =========================================================
# PHASE 4 - test the actual game server
# =========================================================
$lossCount = -1
if($gameIp){
    Log "==================== PHASE 4: SERVER TEST ====================" Cyan
    Log ("Testing the server that kicked you: " + $gameIp + ":" + $gamePort)
    Log ""

    $ping = ping -n 20 -w 2000 $gameIp
    $stat = ($ping | Select-String 'loss').Line
    if($stat){ Log ("  ICMP: " + $stat) }
    $avg = ($ping | Select-String 'Average').Line
    if($avg){ Log ("  ICMP: " + $avg) }

    $lm = $ping | Select-String 'Lost\s*=\s*(\d+)'
    if($lm){ $lossCount = [int]$lm.Matches[0].Groups[1].Value }
    if($lossCount -eq 0){ Log "  ICMP result: PERFECT (0% loss) -> link is fine" Green }
    elseif($lossCount -gt 0 -and $lossCount -le 5){ Log ("  ICMP result: SOME LOSS (" + $lossCount + "/20) -> unstable") Yellow }
    elseif($lossCount -gt 5){ Log ("  ICMP result: HEAVY LOSS (" + $lossCount + "/20) -> route/ISP problem") Red }
    Log ""

    Log "--- MTU to game server (large packet test) ---"
    $mtuOk = $false
    foreach($sz in @(1472,1400,1372,1200,1000)){
        $o = ping -n 1 -f -l $sz -w 2000 $gameIp 2>&1
        if($o -match 'TTL='){
            Log ("  " + $sz + " bytes : OK  (MTU " + ([int]$sz + 28) + ")") Green
            $mtuOk = $true
            break
        }
        elseif($o -match 'fragment'){ Log ("  " + $sz + " bytes : needs fragmentation") Yellow }
    }
    if(-not $mtuOk){ Log "  [WARN] Large packets fail -> set MTU 1400 on your adapter" Red }
    Log ""
}

# =========================================================
# VERDICT
# =========================================================
Log "==================== VERDICT ====================" Cyan

if($isDns){
    Log "  -> Problem is DNS (icons). Run RobloxFixer.bat" Red
}
if($isAck -or $noConn){
    Log "  -> Problem is GAME UDP traffic, not DNS." Red
    Log ""
    Log "  Try in this order:" Yellow
    Log "   1. LAN cable (biggest fix for UDP drops on Wi-Fi)" Yellow
    if($lossCount -eq 0 -and $adName){
        Log "   2. ICMP clean -> likely MTU. Set 1400:" Yellow
        Log ("        netsh interface ipv4 set subinterface """ + $adName + """ mtu=1400 store=persistent") Yellow
    }
    Log "   3. Disable Wi-Fi power save / use 5 GHz" Yellow
    Log "   4. Server region may be bad - try another server" Yellow
}
if(-not ($isDns -or $isAck -or $noConn)){
    Log "  -> No classic signature. Raw tail below - send it to me." Yellow
}

# Offer to apply the MTU fix right away (safe + reversible)
if(($isAck -or $noConn) -and $lossCount -eq 0 -and $adName){
    Log ""
    Log "--- Quick fix: MTU looks like the culprit (ICMP clean but game drops) ---" Cyan
    $apply = Read-Host "  Apply MTU 1400 to '$adName' now? (y/n)"
    if($apply -eq 'y'){
        netsh interface ipv4 set subinterface "`"$adName`"" mtu=1400 store=persistent | Out-Null
        Log "  Applied MTU 1400. Re-join the server to confirm." Green
    } else {
        Log "  Skipped. You can run it later:" Yellow
        Log ("        netsh interface ipv4 set subinterface """ + $adName + """ mtu=1400 store=persistent") Yellow
    }
}

Log ""
Log "--- Last 15 network lines of the log (telemetry noise filtered) ---" Cyan
$tail = $content | Select-String -Pattern 'Network|Connection|Transport|Join|DnsResolve|Timedout|\b277\b' |
    Where-Object { $_.Line -notmatch '1px\.gif|silver\.roblox\.com|pulsar\.roblox\.com|iad\d-[\d\-]+\.roblox\.com' } |
    Select-Object -Last 15
foreach($t in $tail){
    $s = $t.Line
    if($s.Length -gt 200){ $s = $s.Substring(0,200) }
    Log ("  " + $s)
}
Log ""
Log "=================================================" Cyan
Log "  Done. Re-run after each kick to compare."
Log "=================================================" Cyan
