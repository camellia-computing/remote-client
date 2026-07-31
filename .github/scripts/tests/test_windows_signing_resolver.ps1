#requires -Version 7.6

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$resolver = Join-Path $repository '.github/scripts/resolve-windows-signing.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "camellia-remote-signing-$PID"
$null = New-Item -ItemType Directory -Path $testRoot

function Invoke-Resolver {
    param(
        [Parameter(Mandatory)]
        [string] $EnvironmentFile
    )

    $env:GITHUB_ENV = $EnvironmentFile
    $env:RUNNER_TEMP = $testRoot
    & $resolver
}

try {
    $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256 = ''
    $env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT = ''
    $env:WINDOWS_CODESIGN_PFX_BASE64 = ''
    $env:WINDOWS_CODESIGN_PFX_PASSWORD = ''
    $env:WINDOWS_SECONDARY_CODESIGN_CERTIFICATE_SHA256 = ''
    $env:WINDOWS_SECONDARY_CODESIGN_CERTIFICATE_THUMBPRINT = ''
    $env:WINDOWS_SECONDARY_CODESIGN_PFX_BASE64 = ''
    $env:WINDOWS_SECONDARY_CODESIGN_PFX_PASSWORD = ''
    $unsignedEnvironment = Join-Path $testRoot 'unsigned.env'
    Invoke-Resolver -EnvironmentFile $unsignedEnvironment
    $unsigned = Get-Content -LiteralPath $unsignedEnvironment
    if ($unsigned -notcontains 'WINDOWS_NATIVE_SIGNING=unsigned' -or
        $unsigned -notcontains 'WINDOWS_DISTRIBUTION_TRUST=none') {
        throw 'Unsigned Windows signing metadata was not resolved'
    }

    $env:WINDOWS_CODESIGN_PFX_BASE64 = 'partial'
    $partialFailed = $false
    try {
        Invoke-Resolver -EnvironmentFile (Join-Path $testRoot 'partial.env')
    }
    catch {
        $partialFailed = $true
    }
    if (-not $partialFailed) {
        throw 'Partial Windows signing configuration unexpectedly succeeded'
    }

    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=Camellia Remote Resolver Test',
        $rsa,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $enhancedKeyUsage = [Security.Cryptography.OidCollection]::new()
    $null = $enhancedKeyUsage.Add(
        [Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3')
    )
    $request.CertificateExtensions.Add(
        [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
            $enhancedKeyUsage,
            $true
        )
    )
    $certificate = $request.CreateSelfSigned(
        [DateTimeOffset]::UtcNow.AddMinutes(-5),
        [DateTimeOffset]::UtcNow.AddDays(1)
    )
    $password = 'test-only-password'
    $env:WINDOWS_CODESIGN_PFX_BASE64 = [Convert]::ToBase64String(
        $certificate.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
            $password
        )
    )
    $env:WINDOWS_CODESIGN_PFX_PASSWORD = $password
    $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256 = $certificate.GetCertHashString(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    ).ToUpperInvariant()
    $env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT = $certificate.Thumbprint.ToUpperInvariant()
    $signedEnvironment = Join-Path $testRoot 'signed.env'
    Invoke-Resolver -EnvironmentFile $signedEnvironment
    $signed = Get-Content -LiteralPath $signedEnvironment
    if ($signed -notcontains 'WINDOWS_NATIVE_SIGNING=signed' -or
        $signed -notcontains 'WINDOWS_DISTRIBUTION_TRUST=derive' -or
        $signed -notcontains 'WINDOWS_SIGNING_GROUP=primary') {
        throw 'Signed Windows signing metadata was not resolved'
    }
    if (-not ($signed | Where-Object { $_ -match '^WINDOWS_SIGNING_IDENTITY=[0-9A-F]+$' })) {
        throw 'Windows signing identity was not recorded'
    }

    $registeredSha256 = $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256
    $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256 = 'A' * 64
    if ($env:WINDOWS_CODESIGN_CERTIFICATE_SHA256 -eq $registeredSha256) {
        $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256 = 'B' * 64
    }
    $sha256MismatchFailed = $false
    try {
        Invoke-Resolver -EnvironmentFile (Join-Path $testRoot 'sha256-mismatch.env')
    }
    catch {
        $sha256MismatchFailed = $true
    }
    if (-not $sha256MismatchFailed) {
        throw 'A PFX with an unregistered SHA-256 identity unexpectedly succeeded'
    }
    $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256 = $registeredSha256

    $env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT = 'A' * 40
    if ($env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT -eq $certificate.Thumbprint.ToUpperInvariant()) {
        $env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT = 'B' * 40
    }
    $identityMismatchFailed = $false
    try {
        Invoke-Resolver -EnvironmentFile (Join-Path $testRoot 'identity-mismatch.env')
    }
    catch {
        $identityMismatchFailed = $true
    }
    if (-not $identityMismatchFailed) {
        throw 'A PFX with an unregistered Windows signing identity unexpectedly succeeded'
    }

    $env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT = ''
    $env:WINDOWS_CODESIGN_CERTIFICATE_SHA256 = ''
    $env:WINDOWS_CODESIGN_PFX_BASE64 = ''
    $env:WINDOWS_CODESIGN_PFX_PASSWORD = ''
    $env:WINDOWS_SECONDARY_CODESIGN_CERTIFICATE_SHA256 = $registeredSha256
    $env:WINDOWS_SECONDARY_CODESIGN_CERTIFICATE_THUMBPRINT = $certificate.Thumbprint.ToUpperInvariant()
    $env:WINDOWS_SECONDARY_CODESIGN_PFX_BASE64 = [Convert]::ToBase64String(
        $certificate.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
            $password
        )
    )
    $env:WINDOWS_SECONDARY_CODESIGN_PFX_PASSWORD = $password
    $secondaryEnvironment = Join-Path $testRoot 'secondary.env'
    Invoke-Resolver -EnvironmentFile $secondaryEnvironment
    if ((Get-Content -LiteralPath $secondaryEnvironment) -notcontains
        'WINDOWS_SIGNING_GROUP=secondary') {
        throw 'The complete secondary Windows signing group was not selected'
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_CODESIGN_PFX_BASE64 -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_CODESIGN_PFX_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_CODESIGN_CERTIFICATE_SHA256 -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_CODESIGN_CERTIFICATE_THUMBPRINT -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_SECONDARY_CODESIGN_PFX_BASE64 -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_SECONDARY_CODESIGN_PFX_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_SECONDARY_CODESIGN_CERTIFICATE_SHA256 -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_SECONDARY_CODESIGN_CERTIFICATE_THUMBPRINT -ErrorAction SilentlyContinue
}

Write-Host 'Windows signing resolver tests passed'
