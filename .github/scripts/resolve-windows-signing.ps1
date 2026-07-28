#requires -Version 7.6

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    throw 'GITHUB_ENV is required'
}
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or
    -not (Test-Path -LiteralPath $env:RUNNER_TEMP -PathType Container)) {
    throw 'RUNNER_TEMP must identify an existing directory'
}

$values = @(
    $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256,
    $env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT,
    $env:WINDOWS_CODESIGN_PFX_BASE64,
    $env:WINDOWS_CODESIGN_PFX_PASSWORD,
    $env:WINDOWS_SIGNING_TRUST_MODE
)
$configured = @($values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
if ($configured -ne 0 -and $configured -ne $values.Count) {
    throw 'WINDOWS_CODESIGN_CERTIFICATE_SHA256, WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT, WINDOWS_CODESIGN_PFX_BASE64, WINDOWS_CODESIGN_PFX_PASSWORD and WINDOWS_SIGNING_TRUST_MODE must be configured together'
}

if ($configured -eq 0) {
    @(
        'WINDOWS_NATIVE_SIGNING=unsigned',
        'WINDOWS_DISTRIBUTION_TRUST=none'
    ) | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    Write-Host 'Windows artifacts will remain unsigned'
    exit 0
}

if ($env:WINDOWS_SIGNING_TRUST_MODE -notin @('private-trust', 'public-trust')) {
    throw 'WINDOWS_SIGNING_TRUST_MODE must be private-trust or public-trust'
}
$expectedSha256 = $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256
if ($expectedSha256 -cnotmatch '^[0-9A-F]{64}$') {
    throw 'WINDOWS_CODESIGN_CERTIFICATE_SHA256 must be the canonical uppercase 64-hexadecimal leaf fingerprint'
}
$expectedThumbprint = $env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT
if ($expectedThumbprint -cnotmatch '^[0-9A-F]{40}$') {
    throw 'WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT must be the canonical uppercase 40-hexadecimal leaf thumbprint'
}

$base64 = $env:WINDOWS_CODESIGN_PFX_BASE64 -replace '\s', ''
try {
    $pfxBytes = [Convert]::FromBase64String($base64)
}
catch {
    throw 'WINDOWS_CODESIGN_PFX_BASE64 is not valid base64'
}
if ($pfxBytes.Length -eq 0) {
    throw 'WINDOWS_CODESIGN_PFX_BASE64 decoded to an empty file'
}

$pfxPath = Join-Path $env:RUNNER_TEMP 'camellia-remote-windows-signing.pfx'
[IO.File]::WriteAllBytes($pfxPath, $pfxBytes)
try {
    $collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $collection.Import(
        $pfxBytes,
        $env:WINDOWS_CODESIGN_PFX_PASSWORD,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    )
    $now = [DateTimeOffset]::UtcNow
    $candidates = @(
        $collection | Where-Object {
            $eku = @($_.Extensions | Where-Object {
                $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
            } | ForEach-Object { $_.EnhancedKeyUsages | ForEach-Object Value })
            $_.HasPrivateKey -and
            $eku -contains '1.3.6.1.5.5.7.3.3' -and
            $now -ge $_.NotBefore.ToUniversalTime() -and
            $now -le $_.NotAfter.ToUniversalTime()
        }
    )
    if ($candidates.Count -ne 1) {
        throw "The PFX must contain exactly one current private code-signing certificate; found $($candidates.Count)"
    }
    $thumbprint = $candidates[0].Thumbprint.ToUpperInvariant()
    $sha256 = $candidates[0].GetCertHashString(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    ).ToUpperInvariant()
    if ($sha256 -ne $expectedSha256) {
        throw "The PFX leaf fingerprint $sha256 does not match WINDOWS_CODESIGN_CERTIFICATE_SHA256"
    }
    if ($thumbprint -ne $expectedThumbprint) {
        throw "The PFX leaf thumbprint $thumbprint does not match WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT"
    }
}
catch {
    Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
    throw
}

@(
    'WINDOWS_NATIVE_SIGNING=signed',
    "WINDOWS_DISTRIBUTION_TRUST=$($env:WINDOWS_SIGNING_TRUST_MODE)",
    "WINDOWS_SIGNING_CERTIFICATE_SHA256=$sha256",
    "WINDOWS_SIGNING_IDENTITY=$thumbprint",
    "WINDOWS_SIGNING_PFX_PATH=$pfxPath"
) | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
Write-Host "Windows Authenticode signing enabled with certificate $thumbprint"
