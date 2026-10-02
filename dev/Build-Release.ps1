# Builds the release ZIP from the current commit and signs the messenger with the publisher's private key.
#   powershell -ExecutionPolicy Bypass -File dev\Build-Release.ps1
# Output: dist\office-network-kit-v<version>.zip (contains messenger\OfficeMessenger.ps1.sig) and the
# command to publish it. Office PCs running v1.3+ only install updates whose signature matches the
# public key built into OfficeMessenger.ps1.
param(
    [string]$KeyFile = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'office-network-kit-signing\release-signing-key.PRIVATE.xml'),
    [string]$Repo = 'Its-Abishek-01/office-network-kit'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
Set-Location $root

if (-not (Test-Path -LiteralPath $KeyFile)) { throw "Private signing key not found: $KeyFile" }
if (git status --porcelain) { Write-Warning 'There are uncommitted changes - the release is built from the last COMMIT, not from them.' }

$head = git rev-parse --short HEAD
$ps1Text = git show HEAD:messenger/OfficeMessenger.ps1 | Out-String
$version = [regex]::Match($ps1Text, "(?m)^\`$AppVersion\s*=\s*'([0-9.]+)'").Groups[1].Value
if (-not $version) { throw 'Could not read $AppVersion from messenger/OfficeMessenger.ps1' }

New-Item -ItemType Directory -Force (Join-Path $root 'dist') | Out-Null
$zipPath = Join-Path $root "dist\office-network-kit-v$version.zip"
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
git archive --format=zip --prefix=Office-Network-Kit/ -o $zipPath HEAD Setup-This-PC.bat Update-Messenger.bat README.txt LICENSE messenger tools

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Update')
try {
    $entry = $zip.GetEntry('Office-Network-Kit/messenger/OfficeMessenger.ps1')
    $ms = New-Object IO.MemoryStream; $st = $entry.Open(); $st.CopyTo($ms); $st.Close()
    $bytes = $ms.ToArray()                     # exactly the bytes that are shipped

    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider; $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString([IO.File]::ReadAllText($KeyFile))
    $sig = [Convert]::ToBase64String($rsa.SignData($bytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))

    # check against the public key built into the program, exactly as the office PCs will
    $pub = [regex]::Match([Text.Encoding]::UTF8.GetString($bytes), "\`$UpdatePublicKey\s*=\s*'([^']+)'").Groups[1].Value
    $check = New-Object Security.Cryptography.RSACryptoServiceProvider; $check.PersistKeyInCsp = $false; $check.FromXmlString($pub)
    if (-not $check.VerifyData($bytes, [Convert]::FromBase64String($sig), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
        throw 'The private key does not match the public key in OfficeMessenger.ps1 - office PCs would reject this release.'
    }

    $sigEntry = $zip.CreateEntry('Office-Network-Kit/messenger/OfficeMessenger.ps1.sig')
    $w = New-Object IO.StreamWriter($sigEntry.Open(), (New-Object Text.UTF8Encoding($false))); $w.Write($sig); $w.Close()
} finally { $zip.Dispose() }

Write-Host ""
Write-Host "Built and signed: $zipPath" -ForegroundColor Green
Write-Host "  version v$version from commit $head"
Write-Host ""
Write-Host "Publish (from a terminal signed in to GitHub):"
Write-Host "  gh release create v$version dist/office-network-kit-v$version.zip --repo $Repo --target main --title `"v$version`" --notes-file dist/release-notes-v$version.md"
