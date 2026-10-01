@echo off
:: Removes Office Messenger from this PC (double-click, then click Yes).

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -LiteralPath '%~f0' -Raw; Invoke-Expression ($c.Substring($c.IndexOf('#PS' + 'START')))"
echo.
pause
exit /b

#PSSTART
Write-Host ""
Write-Host "=== Remove Office Messenger ===" -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*OfficeMessenger.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Office Messenger.lnk",
                         "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Office Messenger.lnk",
                         "$env:PUBLIC\Desktop\Office Messenger.lnk" -Force -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'Office Messenger*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Remove-Item -LiteralPath "$env:ProgramData\OfficeMessenger" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  [OK]   Office Messenger removed (message history in each user's AppData is kept)" -ForegroundColor Green
