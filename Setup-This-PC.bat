@echo off
:: Office Network Kit - sets up THIS PC for the office network.
:: Double-click, then click Yes. It asks before each part:
::   1. Network sharing  (office network = Private, discovery + file/printer sharing)
::   2. Office Messenger (pop-up messages between office PCs)

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "KIT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -LiteralPath '%~f0' -Raw; Invoke-Expression ($c.Substring($c.IndexOf('#PS' + 'START')))"
echo.
pause
exit /b

#PSSTART
function Ok($m)    { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m)  { Write-Host "  [!!]   $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "  [XX]   $m" -ForegroundColor Red }
function Step($m)  { Write-Host ""; Write-Host "--- $m ---" -ForegroundColor Cyan }
function Ask-YesNo([string]$Question) {
    $a = (Read-Host "  $Question [Y/n]").Trim()
    -not $a -or $a -match '^[Yy]'
}

$Kit  = $env:KIT_DIR.TrimEnd('\')
$Port = 51515
$PS   = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Office Network Kit  -  set up this PC"            -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  PC: $env:COMPUTERNAME"
Write-Host ""
Write-Host "  This will:"
Write-Host "   1. Network sharing  - mark the office network as Private and turn on"
Write-Host "                         Network Discovery + File and Printer Sharing"
Write-Host "                         (Private networks only - not on public Wi-Fi)"
Write-Host "   2. Office Messenger - install the pop-up messenger"
Write-Host ""
Write-Host "  You will be asked before each part."
Write-Host ""
if (-not (Ask-YesNo 'Continue?')) { Write-Host "  Nothing was changed."; return }

# Find the network this PC is connected to (the connection with a router / default gateway)
$net = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
       Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
if (-not $net) {
    Fail "This PC is not connected to a network."
    Fail "Connect it to the office network (cable or Wi-Fi) and run this again. Nothing was changed."
    return
}
$ip      = $net.IPv4Address | Select-Object -First 1
$mac     = $net.NetAdapter.MacAddress
$netName = (Get-NetConnectionProfile -InterfaceIndex $net.InterfaceIndex -ErrorAction SilentlyContinue).Name
Write-Host ""
Write-Host "  Connected network : $netName  (via $($net.InterfaceAlias))"
Write-Host "  This PC's address : $($ip.IPAddress)   router: $($net.IPv4DefaultGateway.NextHop)"
Write-Host ""
if (-not (Ask-YesNo 'Is this your OFFICE network?')) {
    Write-Host "  Connect this PC to the office network and run this again. Nothing was changed."
    return
}
$office = @($ip)

$who = (Read-Host "  Who uses this PC / where is it? (e.g. Priya - Accounts)").Trim()
$newName = $null
$messengerInstalled = $false

# ================================================================ 1. Network sharing
Step '1. Network sharing'
if (Ask-YesNo 'Set up network sharing on this PC?') {
    foreach ($a in $office) {
        try {
            Set-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Ok "$($a.InterfaceAlias) network set to Private"
        } catch { Warn "Could not set $($a.InterfaceAlias) to Private: $($_.Exception.Message)" }
    }

    $groups = @(
        @{ Name = 'Network Discovery';        Id = '@FirewallAPI.dll,-32752' },
        @{ Name = 'File and Printer Sharing'; Id = '@FirewallAPI.dll,-28502' }
    )
    foreach ($g in $groups) {
        $rules = Get-NetFirewallRule -Group $g.Id -ErrorAction SilentlyContinue |
                 Where-Object { $_.Profile.ToString() -match 'Private|Any' }
        if ($rules) { $rules | Enable-NetFirewallRule; Ok "$($g.Name) turned on (Private networks)" }
        else        { Warn "$($g.Name) rules not found" }
    }

    foreach ($s in 'fdPHost', 'FDResPub') {
        try {
            Set-Service -Name $s -StartupType Automatic -ErrorAction Stop
            Start-Service -Name $s -ErrorAction Stop
            Ok "Service $s running and set to Automatic"
        } catch { Warn "Service ${s}: $($_.Exception.Message)" }
    }

    $want = (Read-Host "  New PC name (letters, numbers, - ; max 15). Press Enter to keep '$env:COMPUTERNAME'").Trim()
    if ($want -and $want -ne $env:COMPUTERNAME) {
        if ($want -match '^(?![0-9]+$)[A-Za-z0-9-]{1,15}$') {
            try {
                Rename-Computer -NewName $want -Force -WarningAction SilentlyContinue -ErrorAction Stop
                $newName = $want
                Ok "PC will be renamed to $want after the next restart"
            } catch { Warn "Rename failed: $($_.Exception.Message)" }
        } else { Warn "'$want' is not a valid PC name - skipped" }
    }
} else { Write-Host "  Skipped." }

# ================================================================ 2. Office Messenger
Step '2. Office Messenger'
$desktopLnk = "$env:PUBLIC\Desktop\Office Messenger.lnk"
if (Ask-YesNo 'Install Office Messenger on this PC?') {
    $src = Join-Path $Kit 'messenger'
    $dst = "$env:ProgramData\OfficeMessenger"
    $keyFile = Join-Path $src 'messenger-key.txt'

    # Office key: every PC in the office must use the same one. The first setup creates it in the
    # kit; all later PCs use that copy. (A copy of the kit shared with another office has no key,
    # so that office gets its own.)
    if (-not (Test-Path -LiteralPath $keyFile)) {
        Write-Host ""
        Warn "No office key found in the kit's messenger folder."
        Write-Host "  If Office Messenger is already set up on other PCs in this office, answer n and"
        Write-Host "  copy their messenger-key.txt into the kit first - otherwise they cannot talk to this PC."
        if (Ask-YesNo 'Is this the FIRST PC in this office? Create a new office key?') {
            try {
                $bytes = New-Object byte[] 32
                [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
                [IO.File]::WriteAllText($keyFile, [Convert]::ToBase64String($bytes))
                Ok "New office key created in the kit - use THIS kit for every PC in the office"
            } catch { Fail "Could not create the key (is the pendrive read-only?): $($_.Exception.Message)" }
        }
    }

    $missing = 'OfficeMessenger.ps1', 'messenger-key.txt' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $src $_)) }
    if ($missing) {
        Fail "Missing in the kit's messenger folder: $($missing -join ', '). Messenger not installed."
    } else {
        # stop a running copy (re-install / update)
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*OfficeMessenger.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        try {
            New-Item -ItemType Directory -Path $dst -Force -ErrorAction Stop | Out-Null
            Copy-Item -LiteralPath (Join-Path $src 'OfficeMessenger.ps1'), (Join-Path $src 'messenger-key.txt') -Destination $dst -Force -ErrorAction Stop
            & $PS -NoProfile -ExecutionPolicy Bypass -File "$dst\OfficeMessenger.ps1" -MakeIcon "$dst\OfficeMessenger.ico"
            Ok "Program copied to $dst"

            $cfg = "$dst\config.json"
            $default = if ($who) { $who } else { $env:COMPUTERNAME }
            if (Test-Path $cfg) { try { $n = (Get-Content $cfg -Raw | ConvertFrom-Json).Name; if ($n) { $default = $n } } catch {} }
            $name = (Read-Host "  Name others will see in the messenger [Enter = $default]").Trim()
            if (-not $name) { $name = $default }
            @{ Name = $name } | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding UTF8
            icacls $cfg /grant "*S-1-5-32-545:M" | Out-Null      # users can change the name from the tray menu
            Ok "Messenger name: '$name'"

            Get-NetFirewallRule -DisplayName 'Office Messenger*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            foreach ($proto in 'TCP', 'UDP') {
                New-NetFirewallRule -DisplayName "Office Messenger ($proto)" -Direction Inbound -Action Allow `
                    -Protocol $proto -LocalPort $Port -Program $PS -RemoteAddress LocalSubnet -Profile Private `
                    -ErrorAction Stop | Out-Null
            }
            Ok "Firewall allows the messenger on the office network only (port $Port)"

            $ws = New-Object -ComObject WScript.Shell
            $links = @(
                @{ Path = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Office Messenger.lnk"; Extra = '' },
                @{ Path = $desktopLnk; Extra = '-Show' },
                @{ Path = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Office Messenger.lnk"; Extra = '-Show' }
            )
            foreach ($lnk in $links) {
                $s = $ws.CreateShortcut($lnk.Path)
                $s.TargetPath = $PS
                $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dst\OfficeMessenger.ps1`" $($lnk.Extra)".Trim()
                $s.WorkingDirectory = $dst
                $s.IconLocation = "$dst\OfficeMessenger.ico,0"
                $s.WindowStyle = 7
                $s.Description = 'Office Messenger - send pop-up messages to office PCs'
                $s.Save()
            }
            Ok "Starts with Windows; shortcut on the Desktop and Start menu"
            $messengerInstalled = $true
        } catch { Fail "Messenger install failed: $($_.Exception.Message)" }
    }
} else { Write-Host "  Skipped." }

# Start the messenger as the signed-in user (not as administrator)
if ($messengerInstalled) {
    Start-Process explorer.exe -ArgumentList "`"$desktopLnk`""
    Ok "Office Messenger started - look for the blue chat icon near the clock"
}

# ================================================================ record + summary
$shownName = if ($newName) { "$newName (after restart; was $env:COMPUTERNAME)" } else { $env:COMPUTERNAME }
try {
    $csv = Join-Path $Kit 'office-pcs.csv'
    [pscustomobject]@{ Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Name = $shownName; IP = $ip.IPAddress; MAC = $mac; User = $who } |
        Export-Csv -Path $csv -Append -NoTypeInformation -ErrorAction Stop
    Ok "Recorded in office-pcs.csv"
} catch { Warn "Could not save to office-pcs.csv (pendrive may be read-only)" }

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  PC name   : $shownName"
Write-Host "  IP        : $($ip.IPAddress)"
Write-Host "  User      : $who"
Write-Host "  Messenger : $(if ($messengerInstalled) { 'installed' } else { 'not installed' })"
Write-Host "  Open from other PCs:  \\$($ip.IPAddress)"
if ($newName) { Write-Host "  RESTART this PC when convenient to apply the new name." -ForegroundColor Yellow }
Write-Host "==================================================" -ForegroundColor Cyan
