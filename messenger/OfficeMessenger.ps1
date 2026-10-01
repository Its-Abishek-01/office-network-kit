# Office Messenger - pop-up messages between office PCs on the local network.
# Runs hidden in the system tray. Click the tray icon (or the desktop shortcut)
# to send a message. Messages are signed with the office key, so only PCs that
# have Office Messenger installed can send or receive them.
param(
    [string]$ConfigDir = "$env:ProgramData\OfficeMessenger",
    [int]$Port = 51515,
    [ValidateSet('Any', 'Loopback')][string]$Bind = 'Any',
    [switch]$Show,              # open the Send window on start (desktop shortcut)
    [string]$MakeIcon,          # installer: write the app icon to this .ico path and exit
    [string]$SendTo,            # command line: send -Message to this IP and exit
    [string]$Message,
    [switch]$Urgent,
    [string]$Preview            # testing: render the windows to PNG files in this folder and exit
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')   # must come before any window/control is created

$AppName       = 'Office Messenger'
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

if (-not (Test-Path -LiteralPath $KeyFile)) {
    [void][System.Windows.MessageBox]::Show("$AppName is not installed correctly (office key missing).`nRun Install-Office-Messenger.bat again.", $AppName, 'OK', 'Error')
    return
}
$Hmac = [Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String((Get-Content -LiteralPath $KeyFile -Raw).Trim()))

$MyPc   = $env:COMPUTERNAME
$MyName = $env:USERNAME
if (Test-Path -LiteralPath $CfgFile) {
    try { $n = (Get-Content -LiteralPath $CfgFile -Raw | ConvertFrom-Json).Name; if ($n) { $MyName = $n } } catch {}
}

function Write-History([string]$Line) {
    try { Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd hh:mm tt'), $Line) -Encoding UTF8 } catch {}
}

# ---------------------------------------------------------------- protocol (unchanged - works with older versions)

function Get-SigText($p) { '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $p.type, $p.id, $p.pc, $p.name, $p.ts, $p.text, $p.urgent }
function Get-Sig([string]$s) { [Convert]::ToBase64String($Hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) }

function New-Packet([string]$Type, [string]$Text = '', [bool]$IsUrgent = $false) {
    $p = [ordered]@{
        type = $Type; id = [guid]::NewGuid().ToString('N'); pc = $MyPc; name = $MyName
        ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); text = $Text; urgent = $IsUrgent
    }
    $p.sig = Get-Sig (Get-SigText $p)
    $p | ConvertTo-Json -Compress
}

# Returns the packet if it is signed with the office key and recent, else $null
function Read-Packet([string]$Json) {
    if (-not $Json) { return $null }
    try { $p = $Json | ConvertFrom-Json } catch { return $null }
    if (-not $p -or -not $p.sig -or -not $p.type) { return $null }
    if ((Get-Sig (Get-SigText $p)) -ne $p.sig) { return $null }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$p.ts
    if ([Math]::Abs($age) -gt 900) { return $null }
    $p
}

# Sends one packet over TCP; $true when the other PC confirms it
function Send-OfficePacket([string]$Ip, [string]$Json) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        if (-not $c.ConnectAsync($Ip, $Port).Wait(2500)) { return $false }
        $s = $c.GetStream(); $s.ReadTimeout = 4000; $s.WriteTimeout = 4000
        $w = New-Object IO.StreamWriter($s, (New-Object Text.UTF8Encoding($false))); $w.AutoFlush = $true
        $w.WriteLine($Json)
        $r = New-Object IO.StreamReader($s, [Text.Encoding]::UTF8)
        return ($r.ReadLine() -eq 'OK')
    } catch { return $false } finally { $c.Close() }
}

if ($SendTo) {
    $ok = Send-OfficePacket $SendTo (New-Packet 'msg' $Message $Urgent.IsPresent)
    if ($ok) { "Delivered to $SendTo" } else { "NOT delivered to $SendTo" }
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
    if (Send-OfficePacket $t.Ip (New-Packet 'reply' $text)) {
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
    $n.AvatarBg.Fill  = New-Brush (Get-AvatarColor $p.name)
    $n.Initials.Text  = Get-Initials $p.name
    $n.Title.Text     = $p.name
    $n.Meta.Text      = "$($p.pc)   $([char]0x00B7)   $(Get-Date -Format 'h:mm tt')"
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
        $b.Tag = @{ Win = $win; Ip = $FromIp; To = $p.name; Text = [string]$b.Content }
        $b.Add_Click($OnReplyClick)
    }
    $n.ReplySend.Tag = @{ Win = $win; Ip = $FromIp; To = $p.name; Box = $n.ReplyText }
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
        <Grid Width="44" Height="44">
          <Ellipse Fill="#33FFFFFF"/>
          <TextBlock x:Name="MeInitials" Foreground="White" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="Office Messenger" Foreground="White" FontSize="19" FontWeight="SemiBold"/>
          <TextBlock x:Name="MeName" Foreground="#DBEAFE" FontSize="12.5" Margin="0,2,0,0"/>
        </StackPanel>
        <Button x:Name="RefreshBtn" Grid.Column="2" Style="{StaticResource HeaderBtn}" VerticalAlignment="Center" ToolTip="Look for people online">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center"/>
            <TextBlock Text="Refresh" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
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
    <Ellipse Width="8" Height="8" Fill="#22C55E" VerticalAlignment="Center"/>
    <TextBlock Text="Online" FontSize="12" Foreground="#16A34A" Margin="6,0,0,0" VerticalAlignment="Center"/>
  </StackPanel>
</Grid>
'@

$QuickMessages = 'Come to my desk', 'Call me', 'Meeting now', 'Check your email'

$script:SW = $null
$script:RefreshAt = $null

function New-PersonRow($pe) {
    $row = New-Xaml $PersonXaml
    $row.FindName('Av').Fill  = New-Brush (Get-AvatarColor $pe.Name)
    $row.FindName('Ini').Text = Get-Initials $pe.Name
    $row.FindName('Nm').Text  = $pe.Name
    $row.FindName('Pc').Text  = $pe.Pc
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

    $sig = ($shown | ForEach-Object { "$($_.Pc)=$($_.Name)" }) -join '|'
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
    Send-Udp (New-Packet 'hello?') $script:Broadcasts
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
    $ok = @(); $bad = @()
    foreach ($t in $targets) {
        if (Send-OfficePacket $t.Ip (New-Packet 'msg' $text ([bool]$ui.Urgent.IsChecked))) { $ok += $t.Name } else { $bad += $t.Name }
    }
    if ($ok.Count) { Write-History ("Sent to {0}: {1}" -f ($ok -join ', '), $text) }
    $lines = @()
    if ($ok.Count)  { $lines += "$([char]0x2713)  Delivered to " + ($ok -join ', ') }
    if ($bad.Count) { $lines += "$([char]0x2715)  Not delivered (PC off?): " + ($bad -join ', ') }
    Set-Status ($lines -join "`n") $(if ($bad.Count) { 'error' } else { 'ok' })
    if (-not $bad.Count) { $ui.Msg.Clear(); $ui.Urgent.IsChecked = $false }
    $ui.SendBtn.IsEnabled = $true
}

function New-SendWindow {
    $win = New-Xaml $SendXaml
    $ui = Get-Names $win 'MeInitials', 'MeName', 'RefreshBtn', 'OnlineCount', 'SelectAll', 'Search', 'SearchHint', 'People', 'Empty',
                         'QuickPanel', 'Msg', 'MsgHint', 'Urgent', 'SendBtn', 'SendText', 'Status'
    $ui.Selected = New-Object 'System.Collections.Generic.HashSet[string]'
    $ui.Rebuilding = $false
    $ui.LastSig = $null
    $win.Icon = $WinIcon
    $ui.MeInitials.Text = Get-Initials $MyName
    $ui.MeName.Text = "Signed in as $MyName  ($MyPc)"

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

function Show-NameDialog {
    $win = New-Xaml @'
<Window {{NS}} Title="Office Messenger" Width="420" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="White" FontFamily="Segoe UI" Topmost="True" UseLayoutRounding="True">
  <Window.Resources>{{STYLES}}</Window.Resources>
  <StackPanel Margin="24,22,24,14">
    <TextBlock Text="Your name" FontSize="18" FontWeight="SemiBold" Foreground="#0F172A"/>
    <TextBlock Text="This is how others will see you, for example: Priya - Accounts" FontSize="12.5" Foreground="#64748B" Margin="0,4,0,14" TextWrapping="Wrap"/>
    <Border CornerRadius="10" BorderBrush="#CBD5E1" BorderThickness="1" Background="#F8FAFC" Padding="12,0">
      <TextBox x:Name="NameBox" BorderThickness="0" Background="Transparent" FontSize="14.5" Padding="0,10" MaxLength="40"/>
    </Border>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="CancelBtn" Style="{StaticResource Chip}" Content="Cancel" IsCancel="True" MinWidth="90"/>
      <Button x:Name="SaveBtn" Style="{StaticResource PrimaryChip}" Content="Save" IsDefault="True" MinWidth="90" Margin="0,0,0,10"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $win.Icon = $WinIcon
    $box = $win.FindName('NameBox'); $box.Text = $MyName; $box.SelectAll()
    $win.FindName('SaveBtn').Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    $win.Add_ContentRendered({ $this.FindName('NameBox').Focus() | Out-Null })
    if (-not $win.ShowDialog()) { return }
    $new = $box.Text.Trim()
    if (-not $new) { return }
    $script:MyName = $new
    try { @{ Name = $new } | ConvertTo-Json | Set-Content -LiteralPath $CfgFile -Encoding UTF8 -ErrorAction Stop }
    catch { [void][System.Windows.MessageBox]::Show("Name changed until restart, but could not be saved: $($_.Exception.Message)", $AppName) }
    Set-TrayText
    if ($script:SW) { $script:SW.MeInitials.Text = Get-Initials $new; $script:SW.MeName.Text = "Signed in as $new  ($MyPc)" }
    Send-Udp (New-Packet 'hello') $script:Broadcasts
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

$Peers   = @{}   # pc name -> Pc, Name, Ip, Seen
$SeenIds = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Broadcasts = @()
$script:BroadcastsAt = [DateTime]::MinValue

if ($Preview) {
    New-Item -ItemType Directory -Path $Preview -Force | Out-Null
    # sample data only - fictional names
    $MyPc = 'ADMIN-01'; $MyName = 'Office Admin'
    $fake ={ param($name, $text, $type = 'msg', $urgent = $false) [pscustomobject]@{ type = $type; name = $name; pc = 'SALES-01'; text = $text; urgent = $urgent } }
    Show-Message (& $fake 'Arjun - Sales' 'Please come to my desk, need to discuss the client report.') '127.0.0.1' (Join-Path $Preview 'popup-message.png')
    Show-Message (& $fake 'Meera - HR' 'Meeting now in the conference room!' 'msg' $true) '127.0.0.1' (Join-Path $Preview 'popup-urgent.png')
    Show-Message (& $fake 'Ravi - Support' 'Coming now' 'reply') '127.0.0.1' (Join-Path $Preview 'popup-reply.png')
    $i = 0
    foreach ($nm in 'Anita - Accounts', 'Arjun - Sales', 'Ravi - Support', 'Karthik - Developer', 'Meera - HR', 'Divya - Design') {
        $i++; $Peers["PC-0$i"] = [pscustomobject]@{ Pc = "PC-0$i"; Name = $nm; Ip = '127.0.0.1'; Seen = Get-Date }
    }
    $ui = New-SendWindow
    [void]$ui.Selected.Add('PC-02'); [void]$ui.Selected.Add('PC-03')
    Update-PeopleList
    $ui.Msg.Text = 'Please come to my desk'
    Set-Status "$([char]0x2713)  Delivered to Arjun - Sales, Ravi - Support" 'ok'
    Save-WindowPng $ui.Win (Join-Path $Preview 'send-window.png')
    return
}

# ---------------------------------------------------------------- single instance

$isFirst = $false
$mutex = New-Object Threading.Mutex($true, "Local\OfficeMessenger-$Port", [ref]$isFirst)
$showEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, "Local\OfficeMessenger-Show-$Port")
if (-not $isFirst) { [void]$showEvent.Set(); return }   # already running: just open its Send window

$bindAddr = if ($Bind -eq 'Loopback') { [Net.IPAddress]::Loopback } else { [Net.IPAddress]::Any }
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
    $Peers[$p.pc] = [pscustomobject]@{ Pc = $p.pc; Name = $p.name; Ip = $Ip; Seen = Get-Date }
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
        if ($p.type -eq 'hello?') { Send-Udp (New-Packet 'hello') @($ip) }
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
            $w.WriteLine('OK')
            if (-not $SeenIds.Add($p.id)) { continue }   # duplicate
            Set-Peer $p $ip
            if ($p.type -in 'msg', 'reply') { Show-Message $p $ip }
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

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = $TrayIcon
Set-TrayText
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$miSend = $menu.Items.Add('Send a message', $null, { Show-SendWindow })
$miSend.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add('Message history', $null, {
    if (Test-Path -LiteralPath $LogFile) { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" }
    else { [void][System.Windows.MessageBox]::Show('No messages yet.', $AppName) }
})
[void]$menu.Items.Add('Change my name', $null, { Show-NameDialog })
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
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    try {
        Invoke-Poll
        if ($showEvent.WaitOne(0)) { Show-SendWindow }
        $now = Get-Date
        if ($script:RefreshAt -and $now -ge $script:RefreshAt) { $script:RefreshAt = $null; Update-PeopleList; Set-Status '' }
        if ($script:SW -and ($now - $script:LastListUpdate).TotalSeconds -ge 5) { $script:LastListUpdate = $now; Update-PeopleList }
        if (($now - $script:LastHello).TotalSeconds -ge 60) {
            $script:LastHello = $now
            if (-not $script:Broadcasts.Count -or ($now - $script:BroadcastsAt).TotalMinutes -ge 5) { Update-Broadcasts }
            Send-Udp (New-Packet 'hello') $script:Broadcasts
        }
    } catch { Write-History "Error: $($_.Exception.Message)" }
})

Update-Broadcasts
Send-Udp (New-Packet 'hello?') $script:Broadcasts   # announce ourselves and ask who is online
$timer.Start()
if ($Show) { Show-SendWindow }

[void]$script:App.Run()
$mutex.ReleaseMutex()
