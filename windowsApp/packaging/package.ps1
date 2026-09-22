<#
.SYNOPSIS
  Builds the side-loadable Windows exe: self-contained publish + zip.
  Mirrors appleApp/packaging/package.sh (same $Version train).
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File packaging/package.ps1 -Version 0.4.0
  packaging/package.ps1 -Version 0.4.0 -Arch arm64 -SelfSign
#>
param(
    [string]$Version = "0.4.0",
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [switch]$SelfSign
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$rid = "win-$Arch"
$out = Join-Path $root "dist\$rid"
$zip = Join-Path $root "dist\Rally-$Version-Windows-$Arch.zip"

Write-Host "Publishing Rally.App $Version ($rid)..."
# NOTE: dotnet publish cannot resolve the WinAppSDK PRI tasks (ExpandPriContent
# lives under the VS AppxPackage targets). Publish through VS MSBuild, which CI
# provides via setup-msbuild and dev boxes via VS Build Tools / Community.
function Find-MsBuild {
    $cmd = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -requires Microsoft.Component.MSBuild `
            -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        if ($found) { return $found }
    }
    return $null
}
$msbuild = Find-MsBuild
if (-not $msbuild) { throw "MSBuild not found (install VS Build Tools with the .NET + WinAppSDK workloads)" }
$proj = Join-Path $root "src\Rally.App\Rally.App.csproj"
& $msbuild $proj /t:Publish /p:Configuration=Release /p:RuntimeIdentifier=$rid `
    /p:SelfContained=true /p:Version=$Version "/p:PublishDir=$out\" /restore
if ($LASTEXITCODE -ne 0) { throw "msbuild publish failed" }

$exe = Join-Path $out "Rally.App.exe"
if (-not (Test-Path $exe)) { throw "expected exe missing: $exe" }

if ($SelfSign) {
    $cert = New-SelfSignedCertificate -Type Custom -Subject "CN=Rally" `
        -KeyUsage DigitalSignature -FriendlyName "Rally side-load" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")
    $signtool = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last -ExpandProperty FullName
    if (-not $signtool) { throw "signtool not found (install Windows SDK)" }
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /tr http://timestamp.digicert.com /td SHA256 $exe
    if ($LASTEXITCODE -ne 0) { throw "signtool failed" }
    $cer = Join-Path $root "dist\Rally.cer"
    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    Write-Host "Signed. Trust anchor exported: $cer"
    Write-Host "Install Rally.cer into Local Machine > Trusted People to silence SmartScreen on your boxes."
}

if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip
Write-Host "DONE: $zip"
