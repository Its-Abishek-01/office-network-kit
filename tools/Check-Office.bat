@echo off
:: Office status check - shows every PC on the office network: is Office Messenger running
:: (and which version), and is file sharing on. Read-only: changes nothing, no admin needed.
:: Full paths, so it also works on PCs whose PATH is missing the PowerShell folder
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "KIT_DIR=%~dp0.."
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -LiteralPath '%~f0' -Raw; Invoke-Expression ($c.Substring($c.IndexOf('#PS' + 'START')))"
echo.
pause
exit /b

#PSSTART
$Port = 51515
Write-Host ""
Write-Host "=== Office status check ===" -ForegroundColor Cyan
Write-Host ""

# ---- office key: from this PC's messenger, else from the kit
$keyFile = @("$env:ProgramData\OfficeMessenger\messenger-key.txt", (Join-Path $env:KIT_DIR 'messenger\messenger-key.txt')) |
           Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$hmac = $null
if ($keyFile) { $hmac = [Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String((Get-Content -LiteralPath $keyFile -Raw).Trim())) }
else { Write-Host "  No office key found - messenger versions can't be checked, only whether it is listening." -ForegroundColor Yellow }

# name to use in the check (so older versions don't show a strange name for this PC)
$myName = $env:COMPUTERNAME
try { $n = (Get-Content "$env:ProgramData\OfficeMessenger\config.json" -Raw -ErrorAction Stop | ConvertFrom-Json).Name; if ($n) { $myName = $n } } catch {}

# ---- the network to scan
$net = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
if (-not $net) { Write-Host "  This PC is not connected to a network." -ForegroundColor Red; return }
$me = $net.IPv4Address | Select-Object -First 1
$o = $me.IPAddress.Split('.')
$base = "$($o[0]).$($o[1]).$($o[2])"
if ($me.PrefixLength -lt 24) { Write-Host "  Large network (/$($me.PrefixLength)): checking only $base.1 - $base.254" -ForegroundColor Yellow }
$netName = (Get-NetConnectionProfile -InterfaceIndex $net.InterfaceIndex -ErrorAction SilentlyContinue)
Write-Host "  Network: $($netName.Name)  ($($netName.NetworkCategory))   This PC: $($me.IPAddress)"
if ($netName.NetworkCategory -eq 'Public') { Write-Host "  WARNING: this network is Public on this PC - sharing and the messenger are blocked here. Run Setup-This-PC.bat." -ForegroundColor Red }
Write-Host "  Checking $base.1 - $base.254 ..."
Write-Host ""

# ---- find PCs: try the messenger port and the file sharing port on every address at once
$probes = foreach ($i in 1..254) {
    $ip = "$base.$i"
    $a = New-Object Net.Sockets.TcpClient; $b = New-Object Net.Sockets.TcpClient
    [pscustomobject]@{ Ip = $ip; I = $i; Ma = $a; Mt = $a.ConnectAsync($ip, $Port); Sa = $b; St = $b.ConnectAsync($ip, 445) }
}
Start-Sleep -Milliseconds 2500
$found = foreach ($p in $probes) {
    $msgr = $p.Mt.Status -eq 'RanToCompletion'; $smb = $p.St.Status -eq 'RanToCompletion'
    $p.Ma.Dispose(); $p.Sa.Dispose()
    if ($msgr -or $smb) { [pscustomobject]@{ Ip = $p.Ip; I = $p.I; Messenger = $msgr; Sharing = $smb } }
}

# ---- ask each messenger for its version with a signed check (no pop-up)
function Get-MessengerVersion([string]$Ip) {
    if (-not $hmac) { return 'running' }
    $p = [ordered]@{ type = 'ping'; id = [guid]::NewGuid().ToString('N'); pc = $env:COMPUTERNAME; name = $myName
                     ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); text = ''; urgent = $false }
    $p.sig = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $p.type, $p.id, $p.pc, $p.name, $p.ts, $p.text, $p.urgent))))
    $c = New-Object Net.Sockets.TcpClient
    try {
        if (-not $c.ConnectAsync($Ip, $Port).Wait(2000)) { return 'no answer' }
        $s = $c.GetStream(); $s.ReadTimeout = 3000
        $w = New-Object IO.StreamWriter($s); $w.AutoFlush = $true; $w.WriteLine(($p | ConvertTo-Json -Compress))
        $r = New-Object IO.StreamReader($s)
        $a = $r.ReadLine()
        if ($a -eq 'NO') { return 'DIFFERENT KEY' }
        if ($a -ne 'OK') { return 'no answer' }
        $v = $null; try { $v = $r.ReadLine() } catch {}
        if ($v -like 'VER *') { return 'v' + $v.Substring(4) } else { return 'older (before v1.2)' }
    } catch { return 'no answer' } finally { $c.Close() }
}

# look up all PC names at the same time (each lookup can take a few seconds)
$dns = @{}
foreach ($f in $found) { try { $dns[$f.Ip] = [Net.Dns]::GetHostEntryAsync($f.Ip) } catch {} }
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline -and @($dns.Values | Where-Object { -not $_.IsCompleted }).Count) { Start-Sleep -Milliseconds 200 }

$rows = foreach ($f in ($found | Sort-Object I)) {
    $name = '?'
    $t = $dns[$f.Ip]
    if ($t -and $t.Status -eq 'RanToCompletion') { $name = ($t.Result.HostName -split '\.')[0] }
    [pscustomobject]@{
        Ip = $f.Ip; Pc = $name
        Messenger = if ($f.Messenger) { Get-MessengerVersion $f.Ip } else { '-' }
        Sharing = if ($f.Sharing) { 'on' } else { 'off' }
        Me = ($f.Ip -eq $me.IPAddress)
    }
}

# ---- report
Write-Host ("  {0,-16} {1,-20} {2,-22} {3}" -f 'IP', 'PC', 'Office Messenger', 'File sharing')
Write-Host ("  {0,-16} {1,-20} {2,-22} {3}" -f '--', '--', '----------------', '------------')
foreach ($r in $rows) {
    $color = if ($r.Messenger -match '^v') { 'Green' } elseif ($r.Messenger -match 'older') { 'Yellow' } elseif ($r.Messenger -eq '-') { 'Gray' } else { 'Red' }
    Write-Host ("  {0,-16} {1,-20} {2,-22} {3}" -f $r.Ip, ($r.Pc + $(if ($r.Me) { ' (this PC)' })), $r.Messenger, $r.Sharing) -ForegroundColor $color
}

$withMsgr = @($rows | Where-Object { $_.Messenger -ne '-' })
$noMsgr   = @($rows | Where-Object { $_.Messenger -eq '-' -and $_.Sharing -eq 'on' })
$older    = @($rows | Where-Object { $_.Messenger -match 'older' })
$badKey   = @($rows | Where-Object { $_.Messenger -eq 'DIFFERENT KEY' })
Write-Host ""
Write-Host "  Office Messenger running: $($withMsgr.Count)    PCs found: $(@($rows).Count)" -ForegroundColor Cyan
if ($older.Count)  { Write-Host "  Older version (works, but not encrypted): $(($older | ForEach-Object { $_.Pc }) -join ', ')" -ForegroundColor Yellow }
if ($noMsgr.Count) { Write-Host "  Sharing on but no messenger running (not installed, closed, or nobody signed in): $(($noMsgr | ForEach-Object { $_.Pc }) -join ', ')" -ForegroundColor Yellow }
if ($badKey.Count) { Write-Host "  Set up with a DIFFERENT office key (can't message the others): $(($badKey | ForEach-Object { $_.Pc }) -join ', ')" -ForegroundColor Red }

# PCs recorded by the setup that were not found now
$csv = Join-Path $env:KIT_DIR 'office-pcs.csv'
if (Test-Path -LiteralPath $csv) {
    $seen = @($rows | ForEach-Object { $_.Pc.ToUpper() })
    $known = Import-Csv $csv | ForEach-Object { ($_.Name -split ' ')[0].ToUpper() } | Where-Object { $_ } | Select-Object -Unique
    $missing = @($known | Where-Object { $seen -notcontains $_ })
    if ($missing.Count) { Write-Host "  Set up earlier but not found now (switched off?): $($missing -join ', ')" -ForegroundColor Gray }
}
