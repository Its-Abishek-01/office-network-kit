# Office Messenger - pop-up messages between office PCs on the local network.
# Runs hidden in the system tray. Click the tray icon (or the desktop shortcut)
# to send a message. Messages are signed with the office key, so only PCs that
# have Office Messenger installed can send or receive them.
param(
    [string]$ConfigDir = "$env:ProgramData\OfficeMessenger",
    [int]$Port = 51515,
    [string]$Bind = 'Any',      # 'Any', 'Loopback', or (testing) a 127.x address
    [switch]$Show,              # open the Send window on start (desktop shortcut)
    [string]$MakeIcon,          # installer: write the app icon to this .ico path and exit
    [string]$SendTo,            # command line: send -Message to this IP and exit
    [string]$Message,
    [switch]$Urgent,
    [string]$ToPc,              # command line: recipient PC name -> sends encrypted (needs v1.2+ on that PC)
    [string]$PcName,            # testing: pretend to be this PC
    [string]$Preview,           # testing: render the windows to PNG files in this folder and exit
    [string]$ApplyUpdate,       # updater (run by "Update now"): install the signed update in this folder
    [switch]$ForceAway          # testing: always report Away
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')   # must come before any window/control is created

$AppName       = 'Office Messenger'
$AppVersion    = '1.3.0'
# Updates are only installed if signed with the publisher's private key (kept off-line by the publisher).
# Forks: create your own key with dev\New-SigningKey.ps1 and paste its public key here.
$UpdatePublicKey = '<RSAKeyValue><Modulus>p/TNM8XvlgbB0WK6avoDf/PaD6loxzbQ3CE6lS52BNcsFZ3CDheClhC+GsTIVNvBfaw5hedhb70ilda1Ax6QxaqrPgD2S7WL3mcuKcWz+8mYPl16FIdfbEEajszEcKegiZF08ey7JHM58DoOOVu2+8yqcmQXgK/FPXiomBdGIyybuhqIE2f2F4FATDAK8P7TDd5LDSRL2NOBuTc+zriJH2pl8pYzvHIzqxtCaLjGxYaWN3w4Mq8Vb6UwmzsYlAZl/jMuugKdzoa6ggHHKZrl4dkKNTwCy72O2P+4pMe0icwS6+kkdDLj1UtVia1vh7rNT/Sry/jZ4LAMWK2m0n8R/QGova5w0cswDoB1L7mDvdGxWLsVexOMWghW7FP8VPLsw/99irAUaAdDf5GAKezWGviBDUz7YyswX2bQdgr3u8xtinHv8zfLRmHvZ/bh3CYrXw7hCzDs7M/ssdbO+OqkFyg3jT4GX1O6HHswPwi+zyv5Z4AlDsQp/PVC1Vhv6kDZ</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
$AwayMinutes   = 5       # idle this long (or locked) = Away
$ProjectUrl    = 'https://github.com/Its-Abishek-01/office-network-kit'
$OnlineSeconds = 150     # a PC counts as online if heard from within this time
$AvatarColors  = '#2563EB', '#7C3AED', '#DB2777', '#EA580C', '#059669', '#0891B2', '#CA8A04', '#4F46E5'

# ---------------------------------------------------------------- icon

function New-MessengerBitmap([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(37, 99, 235))), 0, 0, $s - 1, $s - 1)
    $w = [System.Drawing.Brushes]::White
    $g.FillEllipse($w, [int]($s * 0.18), [int]($s * 0.22), [int]($s * 0.64), [int]($s * 0.44))
    $tail = [System.Drawing.Point[]]@(
        (New-Object System.Drawing.Point([int]($s * 0.32), [int]($s * 0.56))),
        (New-Object System.Drawing.Point([int]($s * 0.26), [int]($s * 0.80))),
        (New-Object System.Drawing.Point([int]($s * 0.50), [int]($s * 0.62))))
    $g.FillPolygon($w, $tail)
    $g.Dispose()
    $bmp
}

if ($MakeIcon) {
    # .ico file holding one 64x64 PNG image
    $ms = New-Object IO.MemoryStream
    (New-MessengerBitmap 64).Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray()
    $bw = New-Object IO.BinaryWriter([IO.File]::Create($MakeIcon))
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
    $bw.Write([byte]64); $bw.Write([byte]64); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
    $bw.Write($png)
    $bw.Close()
    return
}

$TrayIcon = [System.Drawing.Icon]::FromHandle((New-MessengerBitmap 32).GetHicon())
$WinIcon  = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($TrayIcon.Handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())

# ---------------------------------------------------------------- config

$CfgFile = Join-Path $ConfigDir 'config.json'
$KeyFile = Join-Path $ConfigDir 'messenger-key.txt'
$LogDir  = Join-Path $env:APPDATA 'OfficeMessenger'
$LogFile = Join-Path $LogDir 'history.txt'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
# profile photo and other people's photos (per Windows user; test copies keep theirs in their own folder)
$DataDir   = if ($ConfigDir -eq "$env:ProgramData\OfficeMessenger") { $LogDir } else { $ConfigDir }
$PhotoFile = Join-Path $DataDir 'my-photo.jpg'
$PhotoDir  = Join-Path $DataDir 'photos'
New-Item -ItemType Directory -Path $PhotoDir -Force -ErrorAction SilentlyContinue | Out-Null

if (-not (Test-Path -LiteralPath $KeyFile)) {
    [void][System.Windows.MessageBox]::Show("$AppName is not installed correctly (office key missing).`nRun Setup-This-PC.bat again.", $AppName, 'OK', 'Error')
    return
}
$OfficeKey = [Convert]::FromBase64String((Get-Content -LiteralPath $KeyFile -Raw).Trim())
$Hmac = [Security.Cryptography.HMACSHA256]::new($OfficeKey)

# v1.2 keys, derived from the same office key (no new key to distribute)
function Get-SubKey([string]$Label) { [Security.Cryptography.HMACSHA256]::new($OfficeKey).ComputeHash([Text.Encoding]::UTF8.GetBytes($Label)) }
$EncKey = Get-SubKey 'office-messenger/v2/encrypt'
$Hmac2  = [Security.Cryptography.HMACSHA256]::new((Get-SubKey 'office-messenger/v2/sign'))

$MyPc   = if ($PcName) { $PcName } else { $env:COMPUTERNAME }
$MyName = $env:USERNAME
$UpdateCheck = $true
if (Test-Path -LiteralPath $CfgFile) {
    try {
        $cfg = Get-Content -LiteralPath $CfgFile -Raw | ConvertFrom-Json
        if ($cfg.Name) { $MyName = $cfg.Name }
        if ($cfg.PSObject.Properties['UpdateCheck'] -and $cfg.UpdateCheck -eq $false) { $UpdateCheck = $false }
        if ($cfg.PSObject.Properties['AwayMinutes'] -and [int]$cfg.AwayMinutes -gt 0) { $AwayMinutes = [int]$cfg.AwayMinutes }
    } catch {}
}

function Get-PhotoHash([byte[]]$Bytes) {
    -join ([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)[0..7] | ForEach-Object { $_.ToString('x2') })
}
$script:MyPhotoHash = ''
if (Test-Path -LiteralPath $PhotoFile) { try { $script:MyPhotoHash = Get-PhotoHash ([IO.File]::ReadAllBytes($PhotoFile)) } catch {} }
$script:IsAway = [bool]$ForceAway

function Write-History([string]$Line) {
    try { Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd hh:mm tt'), $Line) -Encoding UTF8 } catch {}
}

# ---------------------------------------------------------------- protocol
#
# Two packet formats, one JSON line each:
#   v1  (all versions)  {type,id,pc,name,ts,text,urgent,sig}       text in clear, HMAC 'sig'
#   v2  (v1.2+)         {v:2,type,id,pc,name,ts,to,urgent,ver,iv,enc,sig2}
#                       text encrypted with AES-256-CBC, then HMAC 'sig2' over everything (encrypt-then-MAC);
#                       'to' = recipient PC name, so a message can never land on the wrong PC.
# v1.2+ PCs put "caps=2;ver=x.y.z" in the text of their (v1) hello packets. Older PCs ignore that text,
# so they keep working; v1.2+ PCs send v2 to PCs that announced caps=2 and v1 to everyone else.
# Older PCs answer 'NO' to v2 packets (no 'sig' field), so they never show an encrypted message as gibberish.
# v1.3+ also announces "pic=<photo fingerprint>;away=0|1" and answers v2 'getpic' / 'getupdate' requests.

function Get-CapsText { "caps=2;ver=$AppVersion;pic=$($script:MyPhotoHash);away=$(if ($script:IsAway) { 1 } else { 0 })" }

function Get-SigText($p) { '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $p.type, $p.id, $p.pc, $p.name, $p.ts, $p.text, $p.urgent }
function Get-Sig([string]$s) { [Convert]::ToBase64String($Hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) }
function Get-SigText2($p) { '2|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $p.type, $p.id, $p.pc, $p.name, $p.ts, $p.to, $p.urgent, $p.ver, $p.iv, $p.enc }
function Get-Sig2([string]$s) { [Convert]::ToBase64String($Hmac2.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) }

function Test-SameString([string]$a, [string]$b) {   # constant-time compare
    if ($a.Length -ne $b.Length) { return $false }
    $d = 0; for ($i = 0; $i -lt $a.Length; $i++) { $d = $d -bor ([int]$a[$i] -bxor [int]$b[$i]) }
    $d -eq 0
}

function Protect-Text([string]$Text) {
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $EncKey; $aes.GenerateIV()
    $b = [Text.Encoding]::UTF8.GetBytes($Text)
    $c = $aes.CreateEncryptor().TransformFinalBlock($b, 0, $b.Length)
    @{ iv = [Convert]::ToBase64String($aes.IV); enc = [Convert]::ToBase64String($c) }
}
function Unprotect-Text([string]$Iv, [string]$Enc) {
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $EncKey; $aes.IV = [Convert]::FromBase64String($Iv)
    $c = [Convert]::FromBase64String($Enc)
    [Text.Encoding]::UTF8.GetString($aes.CreateDecryptor().TransformFinalBlock($c, 0, $c.Length))
}

# v1 packet (understood by every version)
function New-Packet([string]$Type, [string]$Text = '', [bool]$IsUrgent = $false) {
    $p = [ordered]@{
        type = $Type; id = [guid]::NewGuid().ToString('N'); pc = $MyPc; name = $MyName
        ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); text = $Text; urgent = $IsUrgent
    }
    $p.sig = Get-Sig (Get-SigText $p)
    $p | ConvertTo-Json -Compress
}

# v2 packet: encrypted text, addressed to one PC (only for PCs running v1.2+)
function New-Packet2([string]$Type, [string]$To, [string]$Text, [bool]$IsUrgent = $false) {
    $e = Protect-Text $Text
    $p = [ordered]@{
        v = 2; type = $Type; id = [guid]::NewGuid().ToString('N'); pc = $MyPc; name = $MyName
        ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); to = $To; urgent = $IsUrgent; ver = $AppVersion
        iv = $e.iv; enc = $e.enc
    }
    $p.sig2 = Get-Sig2 (Get-SigText2 $p)
    $p | ConvertTo-Json -Compress
}

# Returns the packet (v2: with .text decrypted) if it is genuine and recent, else $null
function Read-Packet([string]$Json) {
    if (-not $Json) { return $null }
    try { $p = $Json | ConvertFrom-Json } catch { return $null }
    if (-not $p -or -not $p.type) { return $null }
    if ($p.PSObject.Properties['v'] -and $p.v -eq 2) {
        if (-not $p.sig2 -or -not (Test-SameString (Get-Sig2 (Get-SigText2 $p)) $p.sig2)) { return $null }
        try { $text = Unprotect-Text $p.iv $p.enc } catch { return $null }
        $p | Add-Member -NotePropertyName text -NotePropertyValue $text -Force
    } else {
        if (-not $p.sig -or -not (Test-SameString (Get-Sig (Get-SigText $p)) $p.sig)) { return $null }
        $p | Add-Member -NotePropertyName v -NotePropertyValue 1 -Force
    }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$p.ts
    if ([Math]::Abs($age) -gt 900) { return $null }
    $p
}

# "caps=2;ver=1.3.0;pic=ab12..;away=1" -> @{ Caps = 2; Ver = '1.3.0'; Pic = 'ab12..'; Away = $true }
# anything else (older versions) -> Caps 1
function Read-Caps([string]$Text) {
    $r = @{ Caps = 1; Ver = ''; Pic = ''; Away = $false }
    foreach ($part in "$Text".Split(';')) {
        $kv = $part.Split('=', 2)
        if ($kv.Count -ne 2) { continue }
        switch ($kv[0]) {
            'caps' { $n = 0; if ([int]::TryParse($kv[1], [ref]$n)) { $r.Caps = $n } }
            'ver'  { $r.Ver = $kv[1] }
            'pic'  { if ($kv[1] -match '^[0-9a-f]{16}$') { $r.Pic = $kv[1] } }
            'away' { $r.Away = $kv[1] -eq '1' }
        }
    }
    $r
}

function ConvertTo-Version([string]$s) {
    $parts = @(($s.TrimStart('v', 'V') -split '[^0-9]+') | Where-Object { $_ -ne '' } | Select-Object -First 3)
    while ($parts.Count -lt 3) { $parts += '0' }
    try { [version]($parts -join '.') } catch { [version]'0.0.0' }
}

# Sends one packet over TCP. Returns the other PC's answer: 'OK', 'NO', 'WRONG' (not the intended PC) or $null (no answer)
function Send-OfficePacket([string]$Ip, [string]$Json) {
    $c = if ($Bind -in 'Any', 'Loopback') { New-Object Net.Sockets.TcpClient }
         else { New-Object Net.Sockets.TcpClient((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($Bind), 0))) }   # testing: send from our own test address
    try {
        if (-not $c.ConnectAsync($Ip, $Port).Wait(2500)) { return $null }
        $s = $c.GetStream(); $s.ReadTimeout = 4000; $s.WriteTimeout = 4000
        $w = New-Object IO.StreamWriter($s, (New-Object Text.UTF8Encoding($false))); $w.AutoFlush = $true
        $w.WriteLine($Json)
        $r = New-Object IO.StreamReader($s, [Text.Encoding]::UTF8)
        return $r.ReadLine()
    } catch { return $null } finally { $c.Close() }
}

# Like Send-OfficePacket, but returns all lines of the answer (for photo / update requests)
function Send-OfficeRequest([string]$Ip, [string]$Json, [int]$Timeout = 8000) {
    $c = if ($Bind -in 'Any', 'Loopback') { New-Object Net.Sockets.TcpClient }
         else { New-Object Net.Sockets.TcpClient((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($Bind), 0))) }
    try {
        if (-not $c.ConnectAsync($Ip, $Port).Wait(2500)) { return @() }
        $s = $c.GetStream(); $s.ReadTimeout = $Timeout; $s.WriteTimeout = 4000
        $w = New-Object IO.StreamWriter($s, (New-Object Text.UTF8Encoding($false))); $w.AutoFlush = $true
        $w.WriteLine($Json)
        $r = New-Object IO.StreamReader($s, [Text.Encoding]::UTF8)
        $lines = New-Object System.Collections.Generic.List[string]
        while ($null -ne ($l = $r.ReadLine())) { $lines.Add($l); if ($lines.Count -ge 4) { break } }
        return , $lines.ToArray()
    } catch { return @() } finally { $c.Close() }
}

# ---------------------------------------------------------------- signed updates
# A release ships OfficeMessenger.ps1 plus OfficeMessenger.ps1.sig: an RSA-SHA256 signature over the
# exact file bytes, made with the publisher's private key. An update is installed only if the signature
# matches $UpdatePublicKey AND the file is a newer version - wherever it was downloaded from.

function Get-ScriptVersion([byte[]]$Bytes) {
    $m = [regex]::Match([Text.Encoding]::UTF8.GetString($Bytes), "(?m)^\`$AppVersion\s*=\s*'([0-9.]+)'")
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

function Test-UpdateSignature([byte[]]$Bytes, [string]$SigBase64) {
    try {
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($UpdatePublicKey)
        $rsa.VerifyData($Bytes, [Convert]::FromBase64String($SigBase64.Trim()),
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch { $false }
}

# $true when the bytes are a genuine, newer version of this program
function Test-Update([byte[]]$Bytes, [string]$SigBase64) {
    if (-not $Bytes -or -not $SigBase64) { return $false }
    if (-not (Test-UpdateSignature $Bytes $SigBase64)) { return $false }
    (ConvertTo-Version (Get-ScriptVersion $Bytes)) -gt (ConvertTo-Version $AppVersion)
}

if ($ApplyUpdate) {
    # Runs as administrator (started by "Update now"), using THIS - the installed, trusted - copy of the program.
    $target = $PSCommandPath
    $msg = try {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $ApplyUpdate 'OfficeMessenger.ps1'))
        $sig   = [IO.File]::ReadAllText((Join-Path $ApplyUpdate 'OfficeMessenger.ps1.sig'))
        if (-not (Test-UpdateSignature $bytes $sig)) { throw 'The downloaded update is not signed by the publisher, so it was NOT installed.' }
        $newVer = Get-ScriptVersion $bytes
        if ((ConvertTo-Version $newVer) -le (ConvertTo-Version $AppVersion)) { throw "v$newVer is not newer than v$AppVersion." }
        # stop every running copy of this program, replace it, start it again
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$target*" -and $_.CommandLine -notlike '*-ApplyUpdate*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 700
        [IO.File]::WriteAllBytes($target, $bytes)
        [IO.File]::WriteAllText("$target.sig", $sig.Trim())
        "OK:$newVer"
    } catch { "ERROR:$($_.Exception.Message)" }
    try { Remove-Item -LiteralPath $ApplyUpdate -Recurse -Force -ErrorAction SilentlyContinue } catch {}

    $startup = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\Office Messenger.lnk"
    $default = $ConfigDir -eq "$env:ProgramData\OfficeMessenger" -and $Bind -eq 'Any'
    if ($default -and (Test-Path -LiteralPath $startup)) {
        Start-Process "$env:SystemRoot\explorer.exe" -ArgumentList "`"$startup`""     # starts as the signed-in user
    } else {
        $a = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target`""
        if (-not $default) { $a += " -ConfigDir `"$ConfigDir`" -Port $Port -Bind $Bind$(if ($PcName) { " -PcName $PcName" })" }
        Start-Process "$PSHOME\powershell.exe" -ArgumentList $a -WindowStyle Hidden
    }
    if ($msg -like 'OK:*') { [void][System.Windows.MessageBox]::Show("Office Messenger was updated to v$($msg.Substring(3)).", $AppName, 'OK', 'Information') }
    else { [void][System.Windows.MessageBox]::Show("The update was not installed.`n`n$($msg.Substring(6))`n`nOffice Messenger keeps running the current version.", $AppName, 'OK', 'Warning') }
    return
}

if ($SendTo) {
    $json = if ($ToPc) { New-Packet2 'msg' $ToPc $Message $Urgent.IsPresent } else { New-Packet 'msg' $Message $Urgent.IsPresent }
    $ans = Send-OfficePacket $SendTo $json
    $how = if ($ToPc) { "encrypted, to $ToPc" } else { 'not encrypted' }
    switch ($ans) {
        'OK'    { "Delivered to $SendTo ($how)" }
        'WRONG' { "NOT delivered: $SendTo is not $ToPc" }
        'NO'    { "NOT delivered: $SendTo rejected it$(if ($ToPc) { ' (older version? send without -ToPc)' })" }
        default { "NOT delivered to $SendTo (no answer)" }
    }
    return
}

# ---------------------------------------------------------------- UI helpers

$Styles = @'
<Style x:Key="Chip" TargetType="Button">
  <Setter Property="Foreground" Value="#0F172A"/>
  <Setter Property="Background" Value="White"/>
  <Setter Property="BorderBrush" Value="#CBD5E1"/>
  <Setter Property="FontSize" Value="14"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Padding" Value="16,9"/>
  <Setter Property="Margin" Value="0,0,8,10"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="1" CornerRadius="20" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#2563EB"/><Setter TargetName="b" Property="Opacity" Value="0.9"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="PrimaryChip" TargetType="Button" BasedOn="{StaticResource Chip}">
  <Setter Property="Background" Value="#2563EB"/>
  <Setter Property="BorderBrush" Value="#2563EB"/>
  <Setter Property="Foreground" Value="White"/>
</Style>
<Style x:Key="SmallChip" TargetType="Button" BasedOn="{StaticResource Chip}">
  <Setter Property="Background" Value="#EFF6FF"/>
  <Setter Property="BorderBrush" Value="#BFDBFE"/>
  <Setter Property="Foreground" Value="#1D4ED8"/>
  <Setter Property="FontSize" Value="12.5"/>
  <Setter Property="Padding" Value="11,5"/>
</Style>
<Style x:Key="IconBtn" TargetType="Button">
  <Setter Property="Foreground" Value="#64748B"/>
  <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
  <Setter Property="FontSize" Value="11"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Width="32" Height="32" CornerRadius="16" Background="Transparent">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#F1F5F9"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="RoundSend" TargetType="Button">
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Width="38" Height="38" CornerRadius="19" Background="#2563EB">
          <TextBlock Text="&#xE724;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2,0,0,0"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1D4ED8"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="HeaderBtn" TargetType="Button">
  <Setter Property="Foreground" Value="White"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" CornerRadius="18" Background="#26FFFFFF" Padding="14,8">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#40FFFFFF"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="LinkBtn" TargetType="Button">
  <Setter Property="Foreground" Value="#2563EB"/>
  <Setter Property="FontSize" Value="13"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="Transparent" Padding="6,2"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="UrgentToggle" TargetType="CheckBox">
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="CheckBox">
        <Border x:Name="b" CornerRadius="19" BorderThickness="1" BorderBrush="#CBD5E1" Background="White" Padding="14,8">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="i" Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#64748B" VerticalAlignment="Center"/>
            <TextBlock x:Name="t" Text="Urgent" FontSize="13.5" FontWeight="SemiBold" Foreground="#64748B" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#DC2626"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="b" Property="Background" Value="#DC2626"/>
            <Setter TargetName="b" Property="BorderBrush" Value="#DC2626"/>
            <Setter TargetName="t" Property="Foreground" Value="White"/>
            <Setter TargetName="i" Property="Foreground" Value="White"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ListBoxItem">
  <Setter Property="Padding" Value="10,0"/>
  <Setter Property="Margin" Value="0,0,0,4"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="bd" CornerRadius="10" Background="Transparent" BorderThickness="1" BorderBrush="Transparent" Padding="{TemplateBinding Padding}">
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#F8FAFC"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="#EFF6FF"/><Setter TargetName="bd" Property="BorderBrush" Value="#BFDBFE"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@

$Ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

function New-Xaml([string]$Xaml) { [System.Windows.Markup.XamlReader]::Parse($Xaml.Replace('{{NS}}', $Ns).Replace('{{STYLES}}', $Styles)) }
function New-Brush([string]$Hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }
function Get-Names($Win, [string[]]$Names) { $h = @{ Win = $Win }; foreach ($n in $Names) { $h[$n] = $Win.FindName($n) }; $h }

function Get-Initials([string]$Name) {
    $w = @(($Name -replace '[^\p{L}\p{N}]', ' ').Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    if (-not $w.Count) { return '?' }
    if ($w.Count -eq 1) { return $w[0].Substring(0, [Math]::Min(2, $w[0].Length)).ToUpper() }
    ("$($w[0][0])$($w[1][0])").ToUpper()
}
function Get-AvatarColor([string]$Name) {
    $sum = 0; foreach ($ch in $Name.ToCharArray()) { $sum += [int]$ch }
    $AvatarColors[$sum % $AvatarColors.Count]
}

# ---- profile photos: 128x128 JPEG (about 5-10 KB), shared by fingerprint, cached in $PhotoDir

function ConvertTo-PhotoJpeg([string]$Path) {
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.DecodePixelWidth = 512; $bi.UriSource = New-Object Uri($Path); $bi.EndInit()
    $side = [Math]::Min($bi.PixelWidth, $bi.PixelHeight)
    $rect = New-Object System.Windows.Int32Rect([int](($bi.PixelWidth - $side) / 2), [int](($bi.PixelHeight - $side) / 2), $side, $side)
    $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($bi, $rect)
    $scale = 128.0 / $side
    $small = New-Object System.Windows.Media.Imaging.TransformedBitmap($crop, (New-Object System.Windows.Media.ScaleTransform($scale, $scale)))
    $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder; $enc.QualityLevel = 85
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($small))
    $ms = New-Object IO.MemoryStream; $enc.Save($ms); $ms.ToArray()
}

function New-PhotoBrush([byte[]]$Bytes) {
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.StreamSource = New-Object IO.MemoryStream(, $Bytes); $bi.EndInit(); $bi.Freeze()
    $b = New-Object System.Windows.Media.ImageBrush($bi); $b.Stretch = 'UniformToFill'; $b
}

# Brush for a photo fingerprint, or $null if we don't have that photo (yet)
function Get-PhotoBrush([string]$Hash) {
    if (-not $Hash) { return $null }
    if ($Hash -eq $script:MyPhotoHash -and (Test-Path -LiteralPath $PhotoFile)) { $f = $PhotoFile } else { $f = Join-Path $PhotoDir "$Hash.jpg" }
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { New-PhotoBrush ([IO.File]::ReadAllBytes($f)) } catch { $null }
}

# Fill an avatar circle with the photo, or the coloured initials when there is none
function Test-PhotoCached([string]$Hash) {
    if (-not $Hash) { return $false }
    ($Hash -eq $script:MyPhotoHash) -or (Test-Path -LiteralPath (Join-Path $PhotoDir "$Hash.jpg"))
}

function Set-Avatar($Ellipse, $Initials, [string]$Name, [string]$Hash) {
    $brush = Get-PhotoBrush $Hash
    if ($brush) { $Ellipse.Fill = $brush; $Initials.Visibility = 'Collapsed' }
    else { $Ellipse.Fill = New-Brush (Get-AvatarColor $Name); $Initials.Text = Get-Initials $Name; $Initials.Visibility = 'Visible' }
}

# Lets the window repaint while we are busy (e.g. "Sending...")
function Update-Ui { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Render) }

function Start-FadeIn($Win, $Slide) {
    $d = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(260))
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation -Property @{ From = 0; To = 1; Duration = $d }
    $move = New-Object System.Windows.Media.Animation.DoubleAnimation -Property @{ From = -26; To = 0; Duration = $d
        EasingFunction = (New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' }) }
    $Win.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $Slide.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $move)
}

# ---------------------------------------------------------------- pop-up for incoming messages

$PopupXaml = @'
<Window {{NS}} Title="Office Messenger" Width="480" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="True" ShowActivated="True" FontFamily="Segoe UI" UseLayoutRounding="True">
  <Window.Resources>{{STYLES}}</Window.Resources>
  <Border x:Name="Card" Margin="20" CornerRadius="16" Background="White" BorderBrush="#E2E8F0" BorderThickness="1">
    <Border.RenderTransform><TranslateTransform x:Name="Slide"/></Border.RenderTransform>
    <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="6" Direction="270" Opacity="0.25" Color="#0F172A"/></Border.Effect>
    <Grid x:Name="Inner">
    <StackPanel>
      <Border x:Name="Accent" Height="6" Background="#2563EB"/>
      <Grid Margin="22,18,14,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Grid Width="48" Height="48" VerticalAlignment="Center">
          <Ellipse x:Name="AvatarBg" Fill="#2563EB"/>
          <TextBlock x:Name="Initials" Foreground="White" FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel Grid.Column="1" Margin="14,0,8,0" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="Title" FontSize="17" FontWeight="SemiBold" Foreground="#0F172A" TextTrimming="CharacterEllipsis" MaxWidth="240"/>
            <Border x:Name="Badge" Margin="10,0,0,0" CornerRadius="10" Padding="9,2,9,3" VerticalAlignment="Center" Visibility="Collapsed">
              <TextBlock x:Name="BadgeText" FontSize="11" FontWeight="Bold"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="Meta" FontSize="12.5" Foreground="#64748B" Margin="0,3,0,0"/>
        </StackPanel>
        <Button x:Name="CloseBtn" Grid.Column="2" Style="{StaticResource IconBtn}" Content="&#xE711;" VerticalAlignment="Top" ToolTip="Close"/>
      </Grid>
      <ScrollViewer Margin="22,16,22,0" MaxHeight="240" VerticalScrollBarVisibility="Auto">
        <TextBlock x:Name="Body" TextWrapping="Wrap" FontSize="18" Foreground="#0F172A" LineHeight="27"/>
      </ScrollViewer>
      <WrapPanel x:Name="Quick" Margin="22,20,14,0">
        <Button x:Name="Q1" Style="{StaticResource PrimaryChip}" Content="Coming now"/>
        <Button x:Name="Q2" Style="{StaticResource Chip}" Content="Give me 5 min"/>
        <Button x:Name="Q3" Style="{StaticResource Chip}" Content="OK, seen"/>
      </WrapPanel>
      <Border x:Name="ReplyBox" Margin="22,2,22,0" CornerRadius="24" BorderBrush="#E2E8F0" BorderThickness="1" Background="#F8FAFC" Padding="16,4,4,4">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="ReplyHint" Text="Type your own reply..." Foreground="#94A3B8" FontSize="14" VerticalAlignment="Center" IsHitTestVisible="False"/>
          <TextBox x:Name="ReplyText" FontSize="14" Background="Transparent" BorderThickness="0" VerticalContentAlignment="Center" MaxLength="300"/>
          <Button x:Name="ReplySend" Grid.Column="1" Style="{StaticResource RoundSend}" ToolTip="Send reply" Margin="8,0,0,0"/>
        </Grid>
      </Border>
      <Button x:Name="OkBtn" Style="{StaticResource PrimaryChip}" Content="OK" HorizontalAlignment="Right" MinWidth="96" Margin="0,20,22,0" Visibility="Collapsed"/>
      <Border Height="20"/>
    </StackPanel>
    </Grid>
  </Border>
</Window>
'@

$script:PopupCount = 0
$OnReplyClick = {
    $t = $this.Tag
    $text = if ($t.Box) { $t.Box.Text.Trim() } else { $t.Text }
    if (-not $text) { return }
    $t.Win.IsEnabled = $false; Update-Ui
    # answer in the format the message came in: encrypted to v1.2+ PCs, plain v1 to older ones
    $json = if ($t.V -eq 2) { New-Packet2 'reply' $t.Pc $text } else { New-Packet 'reply' $text }
    if ((Send-OfficePacket $t.Ip $json) -eq 'OK') {
        Write-History "Replied to $($t.To): $text"
        $t.Win.Close()
    } else {
        $t.Win.IsEnabled = $true
        [void][System.Windows.MessageBox]::Show("Could not deliver your reply to $($t.To) - their PC may be off.", $AppName, 'OK', 'Warning')
    }
}

function Show-Message($p, [string]$FromIp, [string]$SaveAs) {
    $isReply  = $p.type -eq 'reply'
    $isUrgent = [bool]$p.urgent -and -not $isReply
    if (-not $SaveAs) {
        Write-History ("{0} {1} ({2}): {3}" -f $(if ($isReply) { 'Reply from' } elseif ($isUrgent) { 'URGENT from' } else { 'From' }), $p.name, $p.pc, $p.text)
    }

    $win = New-Xaml $PopupXaml
    $n = Get-Names $win 'Card', 'Inner', 'Slide', 'Accent', 'AvatarBg', 'Initials', 'Title', 'Badge', 'BadgeText', 'Meta', 'CloseBtn',
                        'Body', 'Quick', 'Q1', 'Q2', 'Q3', 'ReplyBox', 'ReplyHint', 'ReplyText', 'ReplySend', 'OkBtn'
    $win.Icon = $WinIcon
    # keep the coloured top strip inside the card's rounded corners
    $n.Inner.Add_SizeChanged({ $this.Clip = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(0, 0, $this.ActualWidth, $this.ActualHeight)), 15, 15) })
    Set-Avatar $n.AvatarBg $n.Initials $p.name $(if ($Peers -and $Peers[$p.pc]) { $Peers[$p.pc].Pic })
    $n.Title.Text     = $p.name
    $n.Meta.Text      = "$($p.pc)   $([char]0x00B7)   $(Get-Date -Format 'h:mm tt')   $([char]0x00B7)   $(if ($p.v -eq 2) { 'Encrypted' } else { 'Not encrypted (older version)' })"
    $n.Body.Text      = $p.text

    if ($isUrgent) {
        $n.Accent.Background = New-Brush '#DC2626'
        $n.Badge.Visibility = 'Visible'; $n.Badge.Background = New-Brush '#FEE2E2'
        $n.BadgeText.Text = 'URGENT'; $n.BadgeText.Foreground = New-Brush '#DC2626'
        foreach ($b in $n.Q1) { $b.Background = New-Brush '#DC2626'; $b.BorderBrush = New-Brush '#DC2626' }
    } elseif ($isReply) {
        $n.Accent.Background = New-Brush '#16A34A'
        $n.Badge.Visibility = 'Visible'; $n.Badge.Background = New-Brush '#DCFCE7'
        $n.BadgeText.Text = 'REPLY'; $n.BadgeText.Foreground = New-Brush '#15803D'
        $n.Quick.Visibility = 'Collapsed'; $n.ReplyBox.Visibility = 'Collapsed'; $n.OkBtn.Visibility = 'Visible'
    }

    foreach ($b in $n.Q1, $n.Q2, $n.Q3) {
        $b.Tag = @{ Win = $win; Ip = $FromIp; To = $p.name; Pc = $p.pc; V = $p.v; Text = [string]$b.Content }
        $b.Add_Click($OnReplyClick)
    }
    $n.ReplySend.Tag = @{ Win = $win; Ip = $FromIp; To = $p.name; Pc = $p.pc; V = $p.v; Box = $n.ReplyText }
    $n.ReplySend.Add_Click($OnReplyClick)
    $n.ReplyText.Tag = $n
    $n.ReplyText.Add_TextChanged({ $this.Tag.ReplyHint.Visibility = if ($this.Text) { 'Collapsed' } else { 'Visible' } })
    $n.ReplyText.Add_KeyDown({ if ($_.Key -eq 'Return') { $_.Handled = $true; $this.Tag.ReplySend.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent, $this.Tag.ReplySend))) } })
    $n.CloseBtn.Add_Click({ [System.Windows.Window]::GetWindow($this).Close() })
    $n.OkBtn.Add_Click({ [System.Windows.Window]::GetWindow($this).Close() })
    $n.Card.Add_MouseLeftButtonDown({ try { [System.Windows.Window]::GetWindow($this).DragMove() } catch {} })

    # Top-centre of the screen; several pop-ups are stacked slightly offset
    $wa = [System.Windows.SystemParameters]::WorkArea
    $off = ($script:PopupCount % 6) * 28; $script:PopupCount++
    $win.WindowStartupLocation = 'Manual'
    $win.Left = $wa.Left + ($wa.Width - $win.Width) / 2 + $off
    $win.Top  = $wa.Top + [Math]::Max(40, $wa.Height * 0.16) + $off

    if ($SaveAs) { Save-WindowPng $win $SaveAs; return }

    $win.Show()
    $win.Activate() | Out-Null
    Start-FadeIn $win $n.Slide
    if ($isUrgent) { [System.Media.SystemSounds]::Hand.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() }
}

# ---------------------------------------------------------------- Send window

$SendXaml = @'
<Window {{NS}} Title="Office Messenger" Width="540" Height="760" MinWidth="460" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#F1F5F9" FontFamily="Segoe UI" UseLayoutRounding="True">
  <Window.Resources>{{STYLES}}</Window.Resources>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <Border Padding="22,18">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#2563EB" Offset="0"/><GradientStop Color="#4F46E5" Offset="1"/></LinearGradientBrush>
      </Border.Background>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Grid x:Name="MeBox" Width="48" Height="48" Cursor="Hand" Background="Transparent" ToolTip="My profile: change your name and photo">
          <Ellipse x:Name="MeAv" Fill="#33FFFFFF" Stroke="#B3FFFFFF" StrokeThickness="2"/>
          <TextBlock x:Name="MeInitials" Foreground="White" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <Border Width="20" Height="20" CornerRadius="10" Background="White" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-3,-3">
            <TextBlock Text="&#xE70F;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#2563EB" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Grid>
        <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="Office Messenger" Foreground="White" FontSize="19" FontWeight="SemiBold"/>
          <TextBlock x:Name="MeName" Foreground="#DBEAFE" FontSize="12.5" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="UpdateBtn" Style="{StaticResource HeaderBtn}" Margin="0,0,8,0" Visibility="Collapsed" ToolTip="Install the new version">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center"/>
              <TextBlock Text="Update" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button x:Name="RefreshBtn" Style="{StaticResource HeaderBtn}" ToolTip="Look for people online">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center"/>
              <TextBlock Text="Refresh" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </StackPanel>
      </Grid>
    </Border>

    <Border Grid.Row="1" Margin="16,16,16,8" Background="White" CornerRadius="14" BorderBrush="#E2E8F0" BorderThickness="1" Padding="14,14,8,8">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions>
        <Grid Margin="2,0,6,10">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Send to" FontSize="15" FontWeight="SemiBold" Foreground="#0F172A" VerticalAlignment="Center"/>
            <Border CornerRadius="10" Background="#DCFCE7" Padding="8,2,8,3" Margin="10,0,0,0" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="7" Height="7" Fill="#22C55E" VerticalAlignment="Center"/>
                <TextBlock x:Name="OnlineCount" Text="0 online" FontSize="11.5" FontWeight="SemiBold" Foreground="#15803D" Margin="6,0,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
          <Button x:Name="SelectAll" Style="{StaticResource LinkBtn}" Content="Select all" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Border Grid.Row="1" CornerRadius="10" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" Padding="12,0" Margin="0,0,6,10">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#94A3B8" VerticalAlignment="Center"/>
            <TextBlock x:Name="SearchHint" Grid.Column="1" Text="Search people" Margin="10,0,0,0" Foreground="#94A3B8" FontSize="13.5" VerticalAlignment="Center" IsHitTestVisible="False"/>
            <TextBox x:Name="Search" Grid.Column="1" Margin="8,0,0,0" FontSize="13.5" Background="Transparent" BorderThickness="0" Padding="0,9" VerticalContentAlignment="Center"/>
          </Grid>
        </Border>
        <ListBox x:Name="People" Grid.Row="2" SelectionMode="Multiple" BorderThickness="0" Background="Transparent"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
        <TextBlock x:Name="Empty" Grid.Row="2" TextAlignment="Center" TextWrapping="Wrap" Foreground="#94A3B8" FontSize="13.5"
                   HorizontalAlignment="Center" VerticalAlignment="Center" Margin="20" LineHeight="21"/>
      </Grid>
    </Border>

    <Border Grid.Row="2" Margin="16,8,16,16" Background="White" CornerRadius="14" BorderBrush="#E2E8F0" BorderThickness="1" Padding="14">
      <StackPanel>
        <WrapPanel x:Name="QuickPanel"/>
        <Border CornerRadius="12" BorderBrush="#E2E8F0" BorderThickness="1" Background="#F8FAFC" Padding="12,8" Margin="0,2,0,0">
          <Grid>
            <TextBlock x:Name="MsgHint" Text="Type your message...  (Ctrl + Enter to send)" Foreground="#94A3B8" FontSize="14" Margin="2,1,0,0" IsHitTestVisible="False"/>
            <TextBox x:Name="Msg" Height="64" FontSize="14.5" Background="Transparent" BorderThickness="0" TextWrapping="Wrap"
                     AcceptsReturn="True" MaxLength="500" VerticalScrollBarVisibility="Auto"/>
          </Grid>
        </Border>
        <Grid Margin="0,12,0,0">
          <CheckBox x:Name="Urgent" Style="{StaticResource UrgentToggle}" HorizontalAlignment="Left" ToolTip="Red pop-up with an alert sound"/>
          <Button x:Name="SendBtn" Style="{StaticResource PrimaryChip}" HorizontalAlignment="Right" Margin="0" MinWidth="130" Padding="20,10">
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="SendText" Text="Send" FontSize="14.5" VerticalAlignment="Center"/>
              <TextBlock Text="&#xE724;" FontFamily="Segoe MDL2 Assets" FontSize="13" Margin="10,1,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </Grid>
        <TextBlock x:Name="Status" TextWrapping="Wrap" FontSize="13" Margin="2,10,0,0" Visibility="Collapsed"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$PersonXaml = @'
<Grid {{NS}} Height="56">
  <Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="50"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <Border Width="22" Height="22" CornerRadius="11" BorderThickness="2" HorizontalAlignment="Left" VerticalAlignment="Center">
    <Border.Style>
      <Style TargetType="Border">
        <Setter Property="BorderBrush" Value="#CBD5E1"/><Setter Property="Background" Value="White"/>
        <Style.Triggers>
          <DataTrigger Binding="{Binding IsSelected, RelativeSource={RelativeSource AncestorType=ListBoxItem}}" Value="True">
            <Setter Property="BorderBrush" Value="#2563EB"/><Setter Property="Background" Value="#2563EB"/>
          </DataTrigger>
        </Style.Triggers>
      </Style>
    </Border.Style>
    <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
  <Grid Grid.Column="1" Width="38" Height="38" HorizontalAlignment="Left">
    <Ellipse x:Name="Av"/>
    <TextBlock x:Name="Ini" Foreground="White" FontSize="14" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Grid>
  <StackPanel Grid.Column="2" VerticalAlignment="Center">
    <TextBlock x:Name="Nm" FontSize="14.5" FontWeight="SemiBold" Foreground="#0F172A" TextTrimming="CharacterEllipsis"/>
    <TextBlock x:Name="Pc" FontSize="12" Foreground="#64748B" Margin="0,1,0,0"/>
  </StackPanel>
  <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,10,0">
    <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#22C55E" VerticalAlignment="Center"/>
    <TextBlock x:Name="State" Text="Online" FontSize="12" Foreground="#16A34A" Margin="6,0,0,0" VerticalAlignment="Center"/>
  </StackPanel>
</Grid>
'@

$QuickMessages = 'Come to my desk', 'Call me', 'Meeting now', 'Check your email'

$script:SW = $null
$script:RefreshAt = $null

function Get-MeText {
    $s = "Signed in as $MyName  ($MyPc)   $([char]0x00B7)   v$AppVersion"
    if ($script:NewerVersion) { $s += "   $([char]0x00B7)   v$($script:NewerVersion) available" }
    $s
}

function New-PersonRow($pe) {
    $row = New-Xaml $PersonXaml
    Set-Avatar $row.FindName('Av') $row.FindName('Ini') $pe.Name $pe.Pic
    if ($pe.Away) {
        $row.FindName('Dot').Fill = New-Brush '#F59E0B'
        $row.FindName('State').Text = 'Away'; $row.FindName('State').Foreground = New-Brush '#B45309'
    }
    $row.FindName('Nm').Text  = $pe.Name
    $row.FindName('Pc').Text  = if ($pe.Caps -ge 2) { "$($pe.Pc)   $([char]0x00B7)   v$($pe.Ver)" } else { "$($pe.Pc)   $([char]0x00B7)   older version (not encrypted)" }
    $row
}

function Set-Status([string]$Text, [string]$Kind = 'muted') {
    $ui = $script:SW; if (-not $ui) { return }
    $ui.Status.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
    $ui.Status.Text = $Text
    $ui.Status.Foreground = New-Brush $(switch ($Kind) { 'ok' { '#15803D' } 'error' { '#DC2626' } default { '#64748B' } })
}

function Update-SendButton {
    $ui = $script:SW; if (-not $ui) { return }
    $c = $ui.Selected.Count
    $ui.SendText.Text = if ($c -gt 1) { "Send to $c" } else { 'Send' }
    $visible = $ui.People.Items.Count
    $ui.SelectAll.Content = if ($visible -and $ui.People.SelectedItems.Count -eq $visible) { 'Clear' } else { 'Select all' }
}

function Update-PeopleList {
    $ui = $script:SW; if (-not $ui) { return }
    $now = Get-Date
    $online = @($Peers.Values | Where-Object { ($now - $_.Seen).TotalSeconds -lt $OnlineSeconds } | Sort-Object Name)
    $filter = $ui.Search.Text.Trim()
    $shown = @($online | Where-Object { -not $filter -or $_.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Pc.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })

    # forget selections of people who went offline
    $onlinePcs = @($online | ForEach-Object { $_.Pc })
    foreach ($s in @($ui.Selected)) { if ($onlinePcs -notcontains $s) { [void]$ui.Selected.Remove($s) } }

    $sig = ($shown | ForEach-Object { "$($_.Pc)=$($_.Name)=$($_.Caps)=$($_.Ver)=$($_.Away)=$($_.Pic)=$(Test-PhotoCached $_.Pic)" }) -join '|'
    if ($sig -ne $ui.LastSig) {
        $ui.Rebuilding = $true
        $ui.People.Items.Clear()
        foreach ($pe in $shown) {
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Content = New-PersonRow $pe
            $item.Tag = $pe.Pc
            [void]$ui.People.Items.Add($item)
            if ($ui.Selected.Contains($pe.Pc)) { $item.IsSelected = $true }
        }
        $ui.Rebuilding = $false
        $ui.LastSig = $sig
    }
    $ui.OnlineCount.Text = "$($online.Count) online"
    $ui.Empty.Visibility = if ($shown.Count) { 'Collapsed' } else { 'Visible' }
    $ui.Empty.Text = if ($online.Count) { 'No one matches your search.' } else { "No one online yet.`nOffice Messenger needs to be running on the other PCs." }
    Update-SendButton
}

function Find-People {
    Update-Broadcasts
    Send-Udp (New-Packet 'hello?' (Get-CapsText)) $script:Broadcasts
    $script:RefreshAt = (Get-Date).AddMilliseconds(900)
    Set-Status 'Looking for people online...'
}

function Invoke-Send {
    $ui = $script:SW; if (-not $ui) { return }
    $text = $ui.Msg.Text.Trim()
    $targets = @($ui.Selected | ForEach-Object { $Peers[$_] } | Where-Object { $_ })
    if (-not $targets.Count) { Set-Status 'Pick at least one person.' 'error'; return }
    if (-not $text) { Set-Status 'Type a message first.' 'error'; $ui.Msg.Focus() | Out-Null; return }

    $ui.SendBtn.IsEnabled = $false
    Set-Status ('Sending to {0}...' -f ($targets.Name -join ', ')); Update-Ui
    $ok = @(); $plain = @(); $bad = @(); $moved = @()
    $away = @($targets | Where-Object { $_.Away } | ForEach-Object { $_.Name })
    $urgent = [bool]$ui.Urgent.IsChecked
    foreach ($t in $targets) {
        # encrypted + addressed for v1.2+ PCs; the old format for PCs that haven't been updated yet
        $json = if ($t.Caps -ge 2) { New-Packet2 'msg' $t.Pc $text $urgent } else { New-Packet 'msg' $text $urgent }
        switch (Send-OfficePacket $t.Ip $json) {
            'OK'    { $ok += $t.Name; if ($t.Caps -lt 2) { $plain += $t.Name } }
            'WRONG' { $moved += $t.Name }      # another PC now has that IP (e.g. after a router restart)
            default { $bad += $t.Name }
        }
    }
    if ($moved.Count) { Find-People; $script:RefreshAt = $null }   # re-learn the addresses
    if ($ok.Count) { Write-History ("Sent to {0}: {1}" -f ($ok -join ', '), $text) }
    $lines = @()
    if ($ok.Count)    { $lines += "$([char]0x2713)  Delivered to " + ($ok -join ', ') }
    if ($plain.Count) { $lines += "      (not encrypted for $($plain -join ', '): older version on that PC)" }
    $awayOk = @($away | Where-Object { $ok -contains $_ })
    if ($awayOk.Count) { $lines += "      ($($awayOk -join ', ') $(if ($awayOk.Count -gt 1) { 'are' } else { 'is' }) away - the message waits on their screen)" }
    if ($moved.Count) { $lines += "$([char]0x2715)  Not delivered - address changed, refreshing; send again in a moment: " + ($moved -join ', ') }
    if ($bad.Count)   { $lines += "$([char]0x2715)  Not delivered (PC off?): " + ($bad -join ', ') }
    $bad += $moved
    Set-Status ($lines -join "`n") $(if ($bad.Count) { 'error' } else { 'ok' })
    if (-not $bad.Count) { $ui.Msg.Clear(); $ui.Urgent.IsChecked = $false }
    $ui.SendBtn.IsEnabled = $true
}

function New-SendWindow {
    $win = New-Xaml $SendXaml
    $ui = Get-Names $win 'MeBox', 'MeAv', 'MeInitials', 'MeName', 'UpdateBtn', 'RefreshBtn', 'OnlineCount', 'SelectAll', 'Search', 'SearchHint',
                         'People', 'Empty', 'QuickPanel', 'Msg', 'MsgHint', 'Urgent', 'SendBtn', 'SendText', 'Status'
    $ui.Selected = New-Object 'System.Collections.Generic.HashSet[string]'
    $ui.Rebuilding = $false
    $ui.LastSig = $null
    $win.Icon = $WinIcon
    Set-Avatar $ui.MeAv $ui.MeInitials $MyName $script:MyPhotoHash
    $ui.MeName.Text = Get-MeText
    $ui.UpdateBtn.Visibility = if ($script:NewerVersion) { 'Visible' } else { 'Collapsed' }
    $ui.MeBox.Add_MouseLeftButtonUp({ Show-ProfileDialog })
    $ui.UpdateBtn.Add_Click({ Start-SelfUpdate })

    foreach ($q in $QuickMessages) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $win.FindResource('SmallChip'); $b.Content = $q
        $b.Add_Click({ $m = $script:SW.Msg; $m.Text = [string]$this.Content; $m.Focus() | Out-Null; $m.CaretIndex = $m.Text.Length })
        [void]$ui.QuickPanel.Children.Add($b)
    }

    $ui.People.Add_SelectionChanged({
        $ui = $script:SW; if (-not $ui -or $ui.Rebuilding) { return }
        foreach ($i in $_.AddedItems)   { [void]$ui.Selected.Add($i.Tag) }
        foreach ($i in $_.RemovedItems) { [void]$ui.Selected.Remove($i.Tag) }
        Update-SendButton
    })
    $ui.SelectAll.Add_Click({
        $l = $script:SW.People
        if ($l.Items.Count -and $l.SelectedItems.Count -eq $l.Items.Count) { $l.UnselectAll() } else { $l.SelectAll() }
    })
    $ui.Search.Add_TextChanged({ $script:SW.SearchHint.Visibility = if ($this.Text) { 'Collapsed' } else { 'Visible' }; Update-PeopleList })
    $ui.Msg.Add_TextChanged({ $script:SW.MsgHint.Visibility = if ($this.Text) { 'Collapsed' } else { 'Visible' } })
    $ui.Msg.Add_PreviewKeyDown({
        if ($_.Key -eq 'Return' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { $_.Handled = $true; Invoke-Send }
    })
    $ui.SendBtn.Add_Click({ Invoke-Send })
    $ui.RefreshBtn.Add_Click({ Find-People })
    $win.Add_Closed({ $script:SW = $null })
    $script:SW = $ui
    $ui
}

function Show-SendWindow {
    if ($script:SW) {
        $w = $script:SW.Win
        if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
        $w.Activate() | Out-Null; return
    }
    $ui = New-SendWindow
    $ui.Win.Show()
    $ui.Win.Topmost = $true; $ui.Win.Activate() | Out-Null; $ui.Win.Topmost = $false
    $ui.Msg.Focus() | Out-Null
    Update-PeopleList
    Find-People
}

function Save-Config([hashtable]$Changes) {
    $h = [ordered]@{}
    if (Test-Path -LiteralPath $CfgFile) { try { (Get-Content -LiteralPath $CfgFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } } catch {} }
    foreach ($k in $Changes.Keys) { $h[$k] = $Changes[$k] }
    [pscustomobject]$h | ConvertTo-Json | Set-Content -LiteralPath $CfgFile -Encoding UTF8 -ErrorAction Stop
}

$ProfileXaml = @'
<Window {{NS}} Title="My profile - Office Messenger" Width="440" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="White" FontFamily="Segoe UI" Topmost="True" UseLayoutRounding="True">
  <Window.Resources>{{STYLES}}</Window.Resources>
  <StackPanel Margin="26,24,26,14">
    <TextBlock Text="My profile" FontSize="19" FontWeight="SemiBold" Foreground="#0F172A"/>
    <TextBlock Text="This is how others see you in their list and on your messages." FontSize="12.5" Foreground="#64748B" Margin="0,4,0,20" TextWrapping="Wrap"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Grid Width="96" Height="96">
        <Ellipse x:Name="Pic" Stroke="#E2E8F0" StrokeThickness="1"/>
        <TextBlock x:Name="PicInitials" Foreground="White" FontSize="32" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Grid>
      <StackPanel Grid.Column="1" Margin="22,0,0,0" VerticalAlignment="Center">
        <Button x:Name="ChooseBtn" Style="{StaticResource PrimaryChip}" HorizontalAlignment="Left" Margin="0,0,0,8">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE722;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center"/>
            <TextBlock Text="Choose photo" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
        <Button x:Name="RemoveBtn" Style="{StaticResource LinkBtn}" Content="Remove photo" HorizontalAlignment="Left"/>
      </StackPanel>
    </Grid>
    <TextBlock Text="Name" FontSize="13" FontWeight="SemiBold" Foreground="#0F172A" Margin="0,24,0,6"/>
    <Border CornerRadius="10" BorderBrush="#CBD5E1" BorderThickness="1" Background="#F8FAFC" Padding="12,0">
      <TextBox x:Name="NameBox" BorderThickness="0" Background="Transparent" FontSize="14.5" Padding="0,10" MaxLength="40"/>
    </Border>
    <TextBlock Text="For example: Priya - Accounts" FontSize="12" Foreground="#94A3B8" Margin="2,6,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
      <Button x:Name="CancelBtn" Style="{StaticResource Chip}" Content="Cancel" IsCancel="True" MinWidth="90"/>
      <Button x:Name="SaveBtn" Style="{StaticResource PrimaryChip}" Content="Save" IsDefault="True" MinWidth="90" Margin="0,0,0,10"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

# Refresh the preview circle in the profile window
function Update-ProfilePreview($ui) {
    if ($ui.State.Photo) { $ui.Pic.Fill = New-PhotoBrush $ui.State.Photo; $ui.PicInitials.Visibility = 'Collapsed' }
    else {
        $n = $ui.NameBox.Text.Trim(); if (-not $n) { $n = $MyName }
        $ui.Pic.Fill = New-Brush (Get-AvatarColor $n); $ui.PicInitials.Text = Get-Initials $n; $ui.PicInitials.Visibility = 'Visible'
    }
    $ui.RemoveBtn.Visibility = if ($ui.State.Photo) { 'Visible' } else { 'Collapsed' }
}

function Show-ProfileDialog([string]$SaveAs, [byte[]]$SamplePhoto) {
    if ($script:ProfileOpen) { return }
    $win = New-Xaml $ProfileXaml
    $ui = Get-Names $win 'Pic', 'PicInitials', 'ChooseBtn', 'RemoveBtn', 'NameBox', 'SaveBtn'
    $ui.State = @{ Photo = $null; Changed = $false }
    if ($SamplePhoto) { $ui.State.Photo = $SamplePhoto }
    elseif (Test-Path -LiteralPath $PhotoFile) { try { $ui.State.Photo = [IO.File]::ReadAllBytes($PhotoFile) } catch {} }
    $win.Icon = $WinIcon
    $win.Tag = $ui
    $ui.NameBox.Text = $MyName
    Update-ProfilePreview $ui

    $ui.ChooseBtn.Add_Click({
        $ui = [System.Windows.Window]::GetWindow($this).Tag
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Choose your photo'
        $dlg.Filter = 'Pictures|*.jpg;*.jpeg;*.png;*.bmp;*.gif|All files|*.*'
        if (-not $dlg.ShowDialog($ui.Win)) { return }
        try { $ui.State.Photo = ConvertTo-PhotoJpeg $dlg.FileName; $ui.State.Changed = $true; Update-ProfilePreview $ui }
        catch { [void][System.Windows.MessageBox]::Show("That file couldn't be opened as a picture.", $AppName, 'OK', 'Warning') }
    })
    $ui.RemoveBtn.Add_Click({ $ui = [System.Windows.Window]::GetWindow($this).Tag; $ui.State.Photo = $null; $ui.State.Changed = $true; Update-ProfilePreview $ui })
    $ui.NameBox.Add_TextChanged({ $ui = [System.Windows.Window]::GetWindow($this).Tag; if ($ui -and -not $ui.State.Photo) { Update-ProfilePreview $ui } })
    $ui.SaveBtn.Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    $win.Add_ContentRendered({ $this.Tag.NameBox.Focus() | Out-Null; $this.Tag.NameBox.SelectAll() })

    if ($SaveAs) { Save-WindowPng $win $SaveAs; return }
    $script:ProfileOpen = $true
    try { $saved = $win.ShowDialog() } finally { $script:ProfileOpen = $false }
    if (-not $saved) { return }

    $new = $ui.NameBox.Text.Trim()
    if ($new -and $new -ne $MyName) {
        $script:MyName = $new
        try { Save-Config @{ Name = $new } }
        catch { [void][System.Windows.MessageBox]::Show("Name changed until restart, but could not be saved: $($_.Exception.Message)", $AppName) }
    }
    if ($ui.State.Changed) {
        try {
            if ($ui.State.Photo) { [IO.File]::WriteAllBytes($PhotoFile, $ui.State.Photo); $script:MyPhotoHash = Get-PhotoHash $ui.State.Photo }
            else { if ([IO.File]::Exists($PhotoFile)) { [IO.File]::Delete($PhotoFile) }; $script:MyPhotoHash = '' }
        } catch { [void][System.Windows.MessageBox]::Show("The photo could not be saved: $($_.Exception.Message)", $AppName) }
    }
    Set-TrayText
    if ($script:SW) { Set-Avatar $script:SW.MeAv $script:SW.MeInitials $MyName $script:MyPhotoHash; $script:SW.MeName.Text = Get-MeText }
    Send-Udp (New-Packet 'hello' (Get-CapsText)) $script:Broadcasts    # others pick up the new name / photo
}

# ---------------------------------------------------------------- preview (testing only)

function Save-WindowPng($Win, [string]$Path) {
    $Win.ShowActivated = $false; $Win.ShowInTaskbar = $false; $Win.Topmost = $false
    $Win.Left = -20000; $Win.Top = -20000
    $Win.Show(); $Win.UpdateLayout()
    $el = $Win.Content; $m = $el.Margin
    $w = [int][Math]::Ceiling($el.ActualWidth + $m.Left + $m.Right); $h = [int][Math]::Ceiling($el.ActualHeight + $m.Top + $m.Bottom)
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bg = New-Object System.Windows.Media.DrawingVisual
    $dc = $bg.RenderOpen(); $dc.DrawRectangle((New-Brush '#CBD5E1'), $null, (New-Object System.Windows.Rect(0, 0, $w, $h))); $dc.Close()
    $rtb.Render($bg)
    $rtb.Render($el)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($Path); $enc.Save($fs); $fs.Close()
    $Win.Close()
}

# ---------------------------------------------------------------- network

$Peers   = @{}   # pc name -> Pc, Name, Ip, Seen, Caps (1 = older version, 2 = v1.2+), Ver, Pic (photo fingerprint), Away
$SeenIds = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Broadcasts = @()
$script:BroadcastsAt = [DateTime]::MinValue

if ($Preview) {
    New-Item -ItemType Directory -Path $Preview -Force | Out-Null
    # sample data only - fictional names
    $MyPc = 'ADMIN-01'; $MyName = 'Office Admin'
    $fake ={ param($name, $text, $type = 'msg', $urgent = $false) [pscustomobject]@{ v = 2; type = $type; name = $name; pc = 'SALES-01'; text = $text; urgent = $urgent } }
    # sample "photos": simple drawn portraits, so no real person appears in the screenshots
    function New-SamplePhoto([string]$From, [string]$To) {
        $dv = New-Object System.Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
        $g = New-Object System.Windows.Media.LinearGradientBrush(([System.Windows.Media.ColorConverter]::ConvertFromString($From)), ([System.Windows.Media.ColorConverter]::ConvertFromString($To)), 45)
        $dc.DrawRectangle($g, $null, (New-Object System.Windows.Rect(0, 0, 128, 128)))
        $skin = New-Brush '#F1C9A5'; $shirt = New-Brush '#FFFFFF'
        $dc.DrawEllipse($shirt, $null, (New-Object System.Windows.Point(64, 132)), 44, 34)
        $dc.DrawEllipse($skin, $null, (New-Object System.Windows.Point(64, 56)), 24, 27)
        $dc.DrawEllipse((New-Brush '#3F2A1D'), $null, (New-Object System.Windows.Point(64, 38)), 25, 14)
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(128, 128, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32); $rtb.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder; $enc.QualityLevel = 85; $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $ms = New-Object IO.MemoryStream; $enc.Save($ms); $ms.ToArray()
    }
    $samples = @{}
    foreach ($s in @(@('Arjun - Sales', '#38BDF8', '#2563EB'), @('Meera - HR', '#F9A8D4', '#DB2777'), @('Divya - Design', '#FDE68A', '#EA580C'))) {
        $bytes = New-SamplePhoto $s[1] $s[2]; $h = Get-PhotoHash $bytes
        [IO.File]::WriteAllBytes((Join-Path $PhotoDir "$h.jpg"), $bytes); $samples[$s[0]] = $h
    }
    $i = 0
    foreach ($nm in 'Anita - Accounts', 'Arjun - Sales', 'Ravi - Support', 'Karthik - Developer', 'Meera - HR', 'Divya - Design') {
        $i++
        $Peers["PC-0$i"] = [pscustomobject]@{ Pc = "PC-0$i"; Name = $nm; Ip = '127.0.0.1'; Seen = Get-Date; Caps = $(if ($i -eq 4) { 1 } else { 2 })
                                              Ver = $AppVersion; Pic = $samples[$nm]; Away = ($i -eq 1) }
    }
    $Peers['SALES-01'] = $Peers['PC-02']   # the pop-up samples come from "SALES-01"
    Show-Message (& $fake 'Arjun - Sales' 'Please come to my desk, need to discuss the client report.') '127.0.0.1' (Join-Path $Preview 'popup-message.png')
    $Peers['SALES-01'] = $Peers['PC-05']
    Show-Message (& $fake 'Meera - HR' 'Meeting now in the conference room!' 'msg' $true) '127.0.0.1' (Join-Path $Preview 'popup-urgent.png')
    $Peers['SALES-01'] = $Peers['PC-03']
    Show-Message (& $fake 'Ravi - Support' 'Coming now' 'reply') '127.0.0.1' (Join-Path $Preview 'popup-reply.png')
    $Peers.Remove('SALES-01')
    $ui = New-SendWindow
    [void]$ui.Selected.Add('PC-01'); [void]$ui.Selected.Add('PC-02')
    Update-PeopleList
    $ui.Msg.Text = 'Please come to my desk'
    Set-Status "$([char]0x2713)  Delivered to Anita - Accounts, Arjun - Sales`n      (Anita - Accounts is away - the message waits on their screen)" 'ok'
    Save-WindowPng $ui.Win (Join-Path $Preview 'send-window.png')
    Show-ProfileDialog (Join-Path $Preview 'profile.png') (New-SamplePhoto '#C4B5FD' '#7C3AED')
    return
}

# ---------------------------------------------------------------- single instance

$instance = if ($Bind -in 'Any', 'Loopback') { "$Port" } else { "$Port-$Bind" }   # testing: one copy per bind address
$isFirst = $false
$mutex = New-Object Threading.Mutex($true, "Local\OfficeMessenger-$instance", [ref]$isFirst)
$showEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, "Local\OfficeMessenger-Show-$instance")
if (-not $isFirst) { [void]$showEvent.Set(); return }   # already running: just open its Send window

$bindAddr = switch ($Bind) { 'Any' { [Net.IPAddress]::Any } 'Loopback' { [Net.IPAddress]::Loopback } default { [Net.IPAddress]::Parse($Bind) } }
$Tcp = New-Object Net.Sockets.TcpListener($bindAddr, $Port)
try { $Tcp.Start() } catch {
    [void][System.Windows.MessageBox]::Show("$AppName could not start: port $Port is already in use on this PC.", $AppName, 'OK', 'Error')
    return
}
$Udp = New-Object Net.Sockets.UdpClient
$Udp.Client.Bind((New-Object Net.IPEndPoint($bindAddr, $Port)))
$Udp.EnableBroadcast = $true
try { [void]$Udp.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch {}   # ignore ICMP 'port unreachable' resets

function Update-Broadcasts {
    $script:BroadcastsAt = Get-Date
    if ($Bind -eq 'Loopback') { $script:Broadcasts = @('127.0.0.1'); return }
    if ($Bind -ne 'Any') { $script:Broadcasts = @('127.0.0.1', '127.0.0.2', '127.0.0.3'); return }   # testing on one PC
    $list = foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($a.IPAddress -like '127.*' -or $a.IPAddress -like '169.254.*' -or $a.PrefixLength -ge 32) { continue }
        $b = [Net.IPAddress]::Parse($a.IPAddress).GetAddressBytes()
        for ($i = 0; $i -lt 4; $i++) {
            $bits = [Math]::Max(0, [Math]::Min(8, $a.PrefixLength - 8 * $i))
            $mask = (0xFF -shl (8 - $bits)) -band 0xFF
            $b[$i] = $b[$i] -bor ((-bnot $mask) -band 0xFF)
        }
        $b -join '.'
    }
    $script:Broadcasts = @($list | Select-Object -Unique)
}

function Send-Udp([string]$Json, [string[]]$To) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
    foreach ($t in $To) { try { [void]$Udp.Send($bytes, $bytes.Length, $t, $Port) } catch {} }
}

function Set-Peer($p, [string]$Ip) {
    if ($p.pc -eq $MyPc) { return }
    $old = $Peers[$p.pc]
    $pic = if ($old) { $old.Pic } else { '' }; $away = if ($old) { $old.Away } else { $false }
    if ($p.type -in 'hello', 'hello?', 'bye') { $c = Read-Caps $p.text; $caps = $c.Caps; $ver = $c.Ver; $pic = $c.Pic; $away = $c.Away }   # announcement
    elseif ($p.v -eq 2) { $caps = 2; $ver = $p.ver }
    elseif ($old -and $old.Caps -ge 2) { $caps = $old.Caps; $ver = $old.Ver }   # v1.2+ PC that hadn't heard our hello yet
    else { $caps = 1; $ver = '' }                                                # older version
    $Peers[$p.pc] = [pscustomobject]@{ Pc = $p.pc; Name = $p.name; Ip = $Ip; Seen = Get-Date; Caps = $caps; Ver = $ver; Pic = $pic; Away = $away }
    if ($ver) { Set-NewerVersion $ver " on $($p.name)'s PC ($($p.pc))" }
}

# Handles everything that has arrived: presence (UDP) and messages (TCP)
function Invoke-Poll {
    while ($Udp.Available -gt 0) {
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        try { $bytes = $Udp.Receive([ref]$ep) } catch { break }
        $p = Read-Packet ([Text.Encoding]::UTF8.GetString($bytes))
        if (-not $p -or $p.pc -eq $MyPc) { continue }
        $ip = $ep.Address.ToString()
        if ($p.type -eq 'bye') { $Peers.Remove($p.pc); continue }
        Set-Peer $p $ip
        if ($p.type -eq 'hello?') { Send-Udp (New-Packet 'hello' (Get-CapsText)) @($ip) }
    }
    while ($Tcp.Pending()) {
        $client = $Tcp.AcceptTcpClient()
        try {
            $ip = $client.Client.RemoteEndPoint.Address.ToString()
            $s = $client.GetStream(); $s.ReadTimeout = 3000; $s.WriteTimeout = 3000
            $r = New-Object IO.StreamReader($s, [Text.Encoding]::UTF8)
            $w = New-Object IO.StreamWriter($s, (New-Object Text.UTF8Encoding($false))); $w.AutoFlush = $true
            $p = Read-Packet ($r.ReadLine())
            if (-not $p) { $w.WriteLine('NO'); continue }
            if ($p.v -eq 2 -and $p.to -ne $MyPc) { $w.WriteLine('WRONG'); continue }   # meant for another PC
            if ($p.type -eq 'getpic') {                                                 # someone wants our photo
                if ($script:MyPhotoHash -and (Test-Path -LiteralPath $PhotoFile)) { $w.WriteLine('OK'); $w.WriteLine([Convert]::ToBase64String([IO.File]::ReadAllBytes($PhotoFile))) }
                else { $w.WriteLine('NO') }
                continue
            }
            if ($p.type -eq 'getupdate') {                                              # a PC on an older version wants ours
                $sigFile = "$PSCommandPath.sig"
                if (Test-Path -LiteralPath $sigFile) {
                    $w.WriteLine('OK'); $w.WriteLine([Convert]::ToBase64String([IO.File]::ReadAllBytes($PSCommandPath))); $w.WriteLine(([IO.File]::ReadAllText($sigFile)).Trim())
                } else { $w.WriteLine('NO') }
                continue
            }
            $w.WriteLine('OK')
            if ($p.type -eq 'ping') { $w.WriteLine("VER $AppVersion"); continue }      # status check tool
            if (-not $SeenIds.Add($p.id)) { continue }   # duplicate
            if ($p.type -in 'msg', 'reply') { Set-Peer $p $ip; Show-Message $p $ip }
        } catch {} finally { $client.Close() }
    }
}

# ---------------------------------------------------------------- tray icon

function Set-TrayText { $t = "$AppName - $MyName"; $script:Tray.Text = $t.Substring(0, [Math]::Min(63, $t.Length)) }

function Stop-Messenger {
    Send-Udp (New-Packet 'bye') $script:Broadcasts
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    try { $Tcp.Stop(); $Udp.Close() } catch {}
    $script:App.Shutdown()
}

# ---------------------------------------------------------------- update notice
# Learns about newer versions from other PCs' announcements (works offline) and, once a day,
# from the project's latest GitHub release. Turn the GitHub check off with "UpdateCheck": false in config.json.

$script:NewerVersion = $null
$script:UpdateTask = $null
$script:NextUpdateCheck = (Get-Date).AddMinutes(2)

function Set-NewerVersion([string]$Ver, [string]$Where) {
    if (-not $Ver) { return }
    $v = ConvertTo-Version $Ver
    if ($v -le (ConvertTo-Version $AppVersion)) { return }
    if ($script:NewerVersion -and (ConvertTo-Version $script:NewerVersion) -ge $v) { return }
    $script:NewerVersion = "$($v.Major).$($v.Minor).$($v.Build)"
    $script:MiUpdate.Text = "Update now to v$($script:NewerVersion)"
    $script:MiUpdate.Visible = $true
    if ($script:SW) { $script:SW.MeName.Text = Get-MeText; $script:SW.UpdateBtn.Visibility = 'Visible' }
    $script:Tray.ShowBalloonTip(10000, $AppName, "A newer version (v$($script:NewerVersion)) is available$Where.`nOpen Office Messenger and click Update.", 'Info')
}

# ---- "Update now": fetch the signed new version (from an office PC that has it, else GitHub), then install it

function Get-UpdateFromPeer {
    $mine = ConvertTo-Version $AppVersion
    $peers = @($Peers.Values | Where-Object { $_.Caps -ge 2 -and $_.Ver -and (ConvertTo-Version $_.Ver) -gt $mine } |
               Sort-Object { ConvertTo-Version $_.Ver } -Descending)
    foreach ($pe in $peers) {
        $a = Send-OfficeRequest $pe.Ip (New-Packet2 'getupdate' $pe.Pc '') 10000
        if ($a.Count -ge 3 -and $a[0] -eq 'OK') {
            try { $bytes = [Convert]::FromBase64String($a[1]) } catch { continue }
            if (Test-Update $bytes $a[2]) { return @{ Bytes = $bytes; Sig = $a[2]; From = "$($pe.Name)'s PC" } }
        }
    }
    $null
}

function Get-UpdateFromGitHub {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient; $wc.Headers.Add('User-Agent', "OfficeMessenger/$AppVersion")
        $api = 'https://api.github.com/repos/' + ($ProjectUrl -replace '^https://github\.com/', '') + '/releases/latest'
        $rel = $wc.DownloadString($api) | ConvertFrom-Json
        $asset = @($rel.assets) | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if (-not $asset) { return $null }
        $wc2 = New-Object Net.WebClient; $wc2.Headers.Add('User-Agent', "OfficeMessenger/$AppVersion")
        $zipBytes = $wc2.DownloadData($asset.browser_download_url)
        Add-Type -AssemblyName System.IO.Compression
        $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $zipBytes)), [IO.Compression.ZipArchiveMode]::Read)
        $read = { param($suffix) $e = $zip.Entries | Where-Object { $_.FullName -like "*$suffix" } | Select-Object -First 1
                  if ($e) { $ms = New-Object IO.MemoryStream; $st = $e.Open(); $st.CopyTo($ms); $st.Close(); , $ms.ToArray() } }
        $bytes = & $read 'messenger/OfficeMessenger.ps1'
        $sigB  = & $read 'messenger/OfficeMessenger.ps1.sig'
        $zip.Dispose()
        if (-not $bytes -or -not $sigB) { return $null }
        $sig = [Text.Encoding]::ASCII.GetString($sigB).Trim()
        if (Test-Update $bytes $sig) { return @{ Bytes = $bytes; Sig = $sig; From = 'GitHub' } }
    } catch {}
    $null
}

# $true if this user can replace the program file (test copies); normally only administrators can
function Test-CanReplaceProgram {
    try { $fs = [IO.File]::Open($PSCommandPath, 'Open', 'ReadWrite', 'ReadWrite'); $fs.Close(); $true } catch { $false }
}

function Start-SelfUpdate {
    if (-not $script:NewerVersion) { return }
    $q = "Update Office Messenger from v$AppVersion to v$($script:NewerVersion)?`n`n" +
         "Windows will ask for permission. Your name, photo and messages are kept, and it takes a few seconds."
    if ([System.Windows.MessageBox]::Show($q, $AppName, 'YesNo', 'Question') -ne 'Yes') { return }
    if ($script:SW) { Set-Status 'Downloading the update...'; Update-Ui }
    $u = Get-UpdateFromPeer
    if (-not $u) { $u = Get-UpdateFromGitHub }
    if ($script:SW) { Set-Status '' }
    if (-not $u) {
        [void][System.Windows.MessageBox]::Show("The update couldn't be downloaded right now (no office PC or GitHub had a valid, signed copy).`n`n" +
            "Try again later, or ask your admin to run Update-Messenger.bat from the kit.", $AppName, 'OK', 'Warning')
        return
    }
    $dir = Join-Path $env:TEMP ("OfficeMessengerUpdate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dir 'OfficeMessenger.ps1'), $u.Bytes)
    [IO.File]::WriteAllText((Join-Path $dir 'OfficeMessenger.ps1.sig'), $u.Sig)
    Write-History "Updating to v$(Get-ScriptVersion $u.Bytes) (downloaded from $($u.From))"
    # the installed (current) program checks the signature again and installs it, as administrator
    $a = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ApplyUpdate `"$dir`""
    if ($ConfigDir -ne "$env:ProgramData\OfficeMessenger" -or $Bind -ne 'Any') { $a += " -ConfigDir `"$ConfigDir`" -Port $Port -Bind $Bind$(if ($PcName) { " -PcName $PcName" })" }
    try {
        if (Test-CanReplaceProgram) { Start-Process "$PSHOME\powershell.exe" -ArgumentList $a -WindowStyle Hidden }
        else { Start-Process "$PSHOME\powershell.exe" -ArgumentList $a -Verb RunAs -WindowStyle Hidden }
    } catch {
        [void][System.Windows.MessageBox]::Show("The update was cancelled (Windows permission was not given).`nOffice Messenger keeps running the current version.", $AppName, 'OK', 'Information')
    }
}

# ---- photos: fetch the ones we don't have yet, one per tick

$script:PhotoTried = @{}   # fingerprint -> time of last attempt
function Receive-NextPhoto {
    $now = Get-Date
    $pe = $Peers.Values | Where-Object { $_.Pic -and $_.Caps -ge 2 -and -not (Test-PhotoCached $_.Pic) -and
                                         (-not $script:PhotoTried[$_.Pic] -or ($now - $script:PhotoTried[$_.Pic]).TotalMinutes -ge 5) } | Select-Object -First 1
    if (-not $pe) { return }
    $script:PhotoTried[$pe.Pic] = $now
    $a = Send-OfficeRequest $pe.Ip (New-Packet2 'getpic' $pe.Pc '') 4000
    if ($a.Count -ge 2 -and $a[0] -eq 'OK') {
        try {
            $bytes = [Convert]::FromBase64String($a[1])
            if ($bytes.Length -le 150KB -and (Get-PhotoHash $bytes) -eq $pe.Pic) {
                [IO.File]::WriteAllBytes((Join-Path $PhotoDir "$($pe.Pic).jpg"), $bytes)
                if ($script:SW) { Update-PeopleList }
            }
        } catch {}
    }
}

# ---- Away: PC locked, or no mouse/keyboard input for $AwayMinutes

Add-Type @'
using System; using System.Runtime.InteropServices;
public static class OmIdle {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    public static uint Seconds() { var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i); if (!GetLastInputInfo(ref i)) return 0; return ((uint)Environment.TickCount - i.dwTime) / 1000; }
}
'@
$MySession = [Diagnostics.Process]::GetCurrentProcess().SessionId
function Test-Away {
    if ($ForceAway) { return $true }
    $locked = @([Diagnostics.Process]::GetProcessesByName('LogonUI') | Where-Object { $_.SessionId -eq $MySession }).Count -gt 0
    $locked -or ([OmIdle]::Seconds() -ge $AwayMinutes * 60)
}
function Update-Away {
    $a = Test-Away
    if ($a -ne $script:IsAway) {
        $script:IsAway = $a
        Send-Udp (New-Packet 'hello' (Get-CapsText)) $script:Broadcasts   # tell everyone right away
    }
}

function Start-UpdateCheck {
    if (-not $UpdateCheck -or $script:UpdateTask) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', "OfficeMessenger/$AppVersion")
        $api = 'https://api.github.com/repos/' + ($ProjectUrl -replace '^https://github\.com/', '') + '/releases/latest'
        $script:UpdateTask = $wc.DownloadStringTaskAsync($api)
    } catch {}
}

function Receive-UpdateCheck {
    $t = $script:UpdateTask
    if (-not $t -or -not $t.IsCompleted) { return }
    $script:UpdateTask = $null
    if ($t.Status -eq 'RanToCompletion') { try { Set-NewerVersion ($t.Result | ConvertFrom-Json).tag_name ' on GitHub' } catch {} }
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $TrayIcon
Set-TrayText
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$miVersion = $menu.Items.Add("$AppName v$AppVersion")
$miVersion.Enabled = $false
$script:MiUpdate = $menu.Items.Add('Update now', $null, { Start-SelfUpdate })
$script:MiUpdate.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$script:MiUpdate.ForeColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
$script:MiUpdate.Visible = $false
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miSend = $menu.Items.Add('Send a message', $null, { Show-SendWindow })
$miSend.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add('Message history', $null, {
    if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" }
    else { [void][System.Windows.MessageBox]::Show('No messages yet.', $AppName) }
})
[void]$menu.Items.Add('My profile (name and photo)', $null, { Show-ProfileDialog })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add('Exit Office Messenger', $null, { Stop-Messenger })
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Show-SendWindow } })
$script:Tray.Visible = $true

# ---------------------------------------------------------------- main loop

$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = 'OnExplicitShutdown'
$script:App.Add_DispatcherUnhandledException({ $_.Handled = $true; Write-History "Error: $($_.Exception.Message)" })
[System.Windows.Forms.Application]::add_ThreadException({ Write-History "Error: $($_.Exception.Message)" })

$script:LastHello = Get-Date
$script:LastListUpdate = Get-Date
$script:LastAwayCheck = Get-Date
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    try {
        Invoke-Poll
        if ($showEvent.WaitOne(0)) { Show-SendWindow }
        $now = Get-Date
        if ($script:RefreshAt -and $now -ge $script:RefreshAt) { $script:RefreshAt = $null; Update-PeopleList; Set-Status '' }
        if ($script:SW -and ($now - $script:LastListUpdate).TotalSeconds -ge 5) { $script:LastListUpdate = $now; Update-PeopleList }
        Receive-UpdateCheck
        if (($now - $script:LastAwayCheck).TotalSeconds -ge 5) { $script:LastAwayCheck = $now; Update-Away; Receive-NextPhoto }
        if ($now -ge $script:NextUpdateCheck) { $script:NextUpdateCheck = $now.AddHours(24); Start-UpdateCheck }
        if (($now - $script:LastHello).TotalSeconds -ge 60) {
            $script:LastHello = $now
            if (-not $script:Broadcasts.Count -or ($now - $script:BroadcastsAt).TotalMinutes -ge 5) { Update-Broadcasts }
            Send-Udp (New-Packet 'hello' (Get-CapsText)) $script:Broadcasts
        }
    } catch { Write-History "Error: $($_.Exception.Message)" }
})

Update-Broadcasts
Send-Udp (New-Packet 'hello?' (Get-CapsText)) $script:Broadcasts   # announce ourselves and ask who is online
$timer.Start()
if ($Show) { Show-SendWindow }

[void]$script:App.Run()
$mutex.ReleaseMutex()
