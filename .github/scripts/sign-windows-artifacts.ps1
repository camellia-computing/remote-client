#requires -Version 7.6

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]] $Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$unsigned = $env:WINDOWS_NATIVE_SIGNING -eq 'unsigned'
if (-not $unsigned -and $env:WINDOWS_NATIVE_SIGNING -ne 'signed') {
    throw "Unexpected WINDOWS_NATIVE_SIGNING value: $($env:WINDOWS_NATIVE_SIGNING)"
}

if (-not $unsigned) {
    foreach ($name in @(
        'WINDOWS_CODESIGN_PFX_PASSWORD',
        'WINDOWS_DISTRIBUTION_TRUST',
        'WINDOWS_SIGNING_IDENTITY',
        'WINDOWS_SIGNING_PFX_PATH'
    )) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "$name is required for Windows signing"
        }
    }
    if ($env:WINDOWS_DISTRIBUTION_TRUST -notin @(
        'derive',
        'private-trust',
        'public-trust'
    )) {
        throw "Unexpected WINDOWS_DISTRIBUTION_TRUST value: $($env:WINDOWS_DISTRIBUTION_TRUST)"
    }
}

function Find-SignTool {
    $fromPath = Get-Command signtool.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $fromPath) {
        return $fromPath.Source
    }

    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $candidates = @(
        foreach ($root in $roots) {
            Get-ChildItem -LiteralPath $root -Filter signtool.exe -File -Recurse |
                Where-Object { $_.Directory.Name -eq $architecture }
        }
    )
    $selected = $candidates |
        Sort-Object {
            $versionText = $_.Directory.Parent.Name
            $parsed = $null
            if ([Version]::TryParse($versionText, [ref] $parsed)) { $parsed } else { [Version]'0.0' }
        } -Descending |
        Select-Object -First 1
    if ($null -eq $selected) {
        throw 'signtool.exe was not found in PATH or an installed Windows SDK'
    }
    return $selected.FullName
}

$signTool = $null
$timestampUrl = $null
if (-not $unsigned) {
    $signTool = Find-SignTool
    $timestampUrl = if ([string]::IsNullOrWhiteSpace($env:WINDOWS_TIMESTAMP_URL)) {
        'http://timestamp.digicert.com'
    }
    else {
        $env:WINDOWS_TIMESTAMP_URL
    }
    if (-not [Uri]::IsWellFormedUriString($timestampUrl, [UriKind]::Absolute)) {
        throw 'WINDOWS_TIMESTAMP_URL must be an absolute URL'
    }
}

$observedTrust = $null
foreach ($requestedPath in $Path) {
    $resolved = Resolve-Path -LiteralPath $requestedPath
    $item = Get-Item -LiteralPath $resolved.Path
    if (-not $item.PSIsContainer -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to sign a reparse point: $requestedPath"
    }
    if ($item.PSIsContainer) {
        throw "Windows signing input must be a file: $requestedPath"
    }
    if ($item.Extension.ToLowerInvariant() -notin @('.exe', '.dll', '.msi')) {
        throw "Unsupported Windows signing extension: $($item.FullName)"
    }

    $before = Get-AuthenticodeSignature -LiteralPath $item.FullName
    if ($before.Status -ne [Management.Automation.SignatureStatus]::NotSigned) {
        throw "Refusing to replace an existing or invalid signature on $($item.FullName): $($before.Status)"
    }
    if ($unsigned) {
        Write-Host "Verified intentionally unsigned Windows artifact: $($item.FullName)"
        continue
    }

    & $signTool sign `
        /fd SHA256 `
        /td SHA256 `
        /tr $timestampUrl `
        /f $env:WINDOWS_SIGNING_PFX_PATH `
        /p $env:WINDOWS_CODESIGN_PFX_PASSWORD `
        $item.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "SignTool failed for $($item.FullName) with exit code $LASTEXITCODE"
    }

    $after = Get-AuthenticodeSignature -LiteralPath $item.FullName
    if ($null -eq $after.SignerCertificate -or
        $after.SignerCertificate.Thumbprint -ne $env:WINDOWS_SIGNING_IDENTITY) {
        throw "Signer mismatch after Authenticode signing: $($item.FullName)"
    }
    if ($null -eq $after.TimeStamperCertificate) {
        throw "RFC 3161 timestamp is missing after signing: $($item.FullName)"
    }
    $fileTrust = if (
        $after.Status -eq [Management.Automation.SignatureStatus]::Valid
    ) {
        'public-trust'
    }
    elseif ($after.Status -in @(
            [Management.Automation.SignatureStatus]::Valid,
            [Management.Automation.SignatureStatus]::UnknownError,
            [Management.Automation.SignatureStatus]::NotTrusted
        )
    ) {
        'private-trust'
    }
    else {
        throw "Authenticode validation failed for $($item.FullName): $($after.Status)"
    }
    if ($null -ne $observedTrust -and $observedTrust -ne $fileTrust) {
        throw 'One credential produced inconsistent Windows trust results'
    }
    $observedTrust = $fileTrust
    if ($env:WINDOWS_DISTRIBUTION_TRUST -ne 'derive' -and
        $env:WINDOWS_DISTRIBUTION_TRUST -ne $fileTrust) {
        throw "Windows trust changed from $($env:WINDOWS_DISTRIBUTION_TRUST) to $fileTrust"
    }
    Write-Host "Verified Authenticode signer and timestamp: $($item.FullName)"
}

if (-not $unsigned -and $env:WINDOWS_DISTRIBUTION_TRUST -eq 'derive') {
    if ($observedTrust -notin @('private-trust', 'public-trust')) {
        throw 'Windows trust could not be derived from the signed artifacts'
    }
    "WINDOWS_DISTRIBUTION_TRUST=$observedTrust" |
        Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    $env:WINDOWS_DISTRIBUTION_TRUST = $observedTrust
    Write-Host "Windows distribution trust derived as $observedTrust"
}
