@echo off
:: One-click update of Office Messenger on this PC: double-click, then click Yes.
:: Keeps the name, photo, office key and network settings. For a brand-new PC use Setup-This-PC.bat.
:: Full paths, so it also works on PCs whose PATH is missing the PowerShell folder
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%SystemRoot%\System32\net.exe" session >nul 2>&1
if errorlevel 1 (
    "%PSEXE%" -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "KIT_DIR=%~dp0"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -LiteralPath '%~f0' -Raw; Invoke-Expression ($c.Substring($c.IndexOf('#PS' + 'START')))"
if errorlevel 1 (
    echo.
    pause
)
exit /b

#PSSTART
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  [XX]   $m" -ForegroundColor Red }

$Kit  = $env:KIT_DIR.TrimEnd('\')
$Src  = Join-Path $Kit 'messenger'
$Dst  = "$env:ProgramData\OfficeMessenger"
$Port = 51515
$PS   = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

Write-Host ""
Write-Host "=== Update Office Messenger ===" -ForegroundColor Cyan
Write-Host ""

function Get-Ver([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    $m = [regex]::Match((Get-Content -LiteralPath $File -Raw), "(?m)^\`$AppVersion\s*=\s*'([0-9.]+)'")
    if ($m.Success) { $m.Groups[1].Value } else { 'older than 1.2' }
}

if (-not (Test-Path -LiteralPath "$Dst\messenger-key.txt")) {
    Fail "Office Messenger is not installed on this PC yet."
    Fail "Run Setup-This-PC.bat instead (it installs everything)."
    exit 1
}
if (-not (Test-Path -LiteralPath "$Src\OfficeMessenger.ps1")) { Fail "messenger\OfficeMessenger.ps1 is missing from the kit."; exit 1 }

$from = Get-Ver "$Dst\OfficeMessenger.ps1"
$to   = Get-Ver "$Src\OfficeMessenger.ps1"
Write-Host "  This PC: v$from   ->   kit: v$to"

try {
    # stop the running messenger (every user), replace the program, keep config/key/photos
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*OfficeMessenger.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
    Copy-Item -LiteralPath "$Src\OfficeMessenger.ps1" -Destination $Dst -Force -ErrorAction Stop
    if (Test-Path -LiteralPath "$Src\OfficeMessenger.ps1.sig") { Copy-Item -LiteralPath "$Src\OfficeMessenger.ps1.sig" -Destination $Dst -Force -ErrorAction Stop }
    & $PS -NoProfile -ExecutionPolicy Bypass -File "$Dst\OfficeMessenger.ps1" -MakeIcon "$Dst\OfficeMessenger.ico"
    Ok "Program updated (name, photo and office key kept)"

    # firewall rules (re-created only if missing)
    if (-not (Get-NetFirewallRule -DisplayName 'Office Messenger*' -ErrorAction SilentlyContinue)) {
        foreach ($proto in 'TCP', 'UDP') {
            New-NetFirewallRule -DisplayName "Office Messenger ($proto)" -Direction Inbound -Action Allow -Protocol $proto -LocalPort $Port `
                -Program $PS -RemoteAddress LocalSubnet -Profile Private -ErrorAction Stop | Out-Null
        }
        Ok "Firewall rules restored"
    }

    # shortcuts: start with no console window (also fixes PCs set up with v1.0)
    $conhost  = "$env:SystemRoot\System32\conhost.exe"
    $psArgs   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Dst\OfficeMessenger.ps1`""
    $headless = ([Environment]::OSVersion.Version.Build -ge 17763) -and (Test-Path $conhost)
    $startup  = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Office Messenger.lnk"
    $ws = New-Object -ComObject WScript.Shell
    foreach ($lnk in @(@{ Path = $startup; Extra = '' },
                       @{ Path = "$env:PUBLIC\Desktop\Office Messenger.lnk"; Extra = '-Show' },
                       @{ Path = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Office Messenger.lnk"; Extra = '-Show' })) {
        $s = $ws.CreateShortcut($lnk.Path)
        if ($headless) { $s.TargetPath = $conhost; $s.Arguments = "--headless `"$PS`" $psArgs $($lnk.Extra)".Trim() }
        else           { $s.TargetPath = $PS;      $s.Arguments = "$psArgs $($lnk.Extra)".Trim() }
        $s.WorkingDirectory = $Dst
        $s.IconLocation = "$Dst\OfficeMessenger.ico,0"
        $s.WindowStyle = 7
        $s.Description = 'Office Messenger - send pop-up messages to office PCs'
        $s.Save()
    }

    # start it again as the signed-in user (not as administrator)
    Start-Process "$env:SystemRoot\explorer.exe" -ArgumentList "`"$startup`""
    Ok "Office Messenger restarted"
} catch {
    Fail "Update failed: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Host "  Done: Office Messenger v$to. This window closes in 5 seconds." -ForegroundColor Cyan
Start-Sleep -Seconds 5
exit 0
