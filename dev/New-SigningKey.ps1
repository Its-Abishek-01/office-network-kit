# Creates a release signing key pair - only needed if you publish your OWN builds (e.g. a fork).
#   powershell -ExecutionPolicy Bypass -File dev\New-SigningKey.ps1
# Then paste the printed public key into $UpdatePublicKey in messenger\OfficeMessenger.ps1.
# Keep the private key OUT of the repository (the default folder is next to it, not inside it).
param([string]$Folder = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'office-network-kit-signing'))

$priv = Join-Path $Folder 'release-signing-key.PRIVATE.xml'
if (Test-Path -LiteralPath $priv) { throw "A key already exists: $priv (delete it yourself first if you really want a new one)" }
New-Item -ItemType Directory -Force $Folder | Out-Null
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072); $rsa.PersistKeyInCsp = $false
[IO.File]::WriteAllText($priv, $rsa.ToXmlString($true))
[IO.File]::WriteAllText((Join-Path $Folder 'release-signing-key.public.xml'), $rsa.ToXmlString($false))
icacls $priv /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null

Write-Host "Private key (keep secret, back it up): $priv" -ForegroundColor Yellow
Write-Host ""
Write-Host "Public key - paste into `$UpdatePublicKey in messenger\OfficeMessenger.ps1:"
Write-Host $rsa.ToXmlString($false)
