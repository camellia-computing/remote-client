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
    $env:WINDOWS_CODESIGN_PFX_BASE64 = ''
    $env:WINDOWS_CODESIGN_PFX_PASSWORD = ''
    $env:WINDOWS_SIGNING_TRUST_MODE = ''
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
    $env:WINDOWS_SIGNING_TRUST_MODE = 'private-trust'
    $signedEnvironment = Join-Path $testRoot 'signed.env'
    Invoke-Resolver -EnvironmentFile $signedEnvironment
    $signed = Get-Content -LiteralPath $signedEnvironment
    if ($signed -notcontains 'WINDOWS_NATIVE_SIGNING=signed' -or
        $signed -notcontains 'WINDOWS_DISTRIBUTION_TRUST=private-trust') {
        throw 'Signed Windows signing metadata was not resolved'
    }
    if (-not ($signed | Where-Object { $_ -match '^WINDOWS_SIGNING_IDENTITY=[0-9A-F]+$' })) {
        throw 'Windows signing identity was not recorded'
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_CODESIGN_PFX_BASE64 -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_CODESIGN_PFX_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:WINDOWS_SIGNING_TRUST_MODE -ErrorAction SilentlyContinue
}

Write-Host 'Windows signing resolver tests passed'
