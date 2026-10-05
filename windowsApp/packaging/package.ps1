<#
.SYNOPSIS
  Builds the side-loadable Windows exe: self-contained publish + zip.
  Mirrors appleApp/packaging/package.sh (same $Version train).
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File packaging/package.ps1 -Version 0.8.0
  packaging/package.ps1 -Version 0.8.0 -Arch arm64 -SelfSign
#>
param(
    [string]$Version = "0.8.0",
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [switch]$SelfSign
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$rid = "win-$Arch"
$out = Join-Path $root "dist\$rid"
$platform = if ($Arch -eq "arm64") { "ARM64" } else { "x64" }
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
            -find 'MSBuild\**\Bin\*MSBuild.exe' | Select-Object -First 1
        if ($found) {
            if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
                $native = Join-Path (Split-Path $found) "arm64\MSBuild.exe"
                if (Test-Path $native) { return $native }
            }
            return $found
        }
    }
    $fallback = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\arm64\MSBuild.exe", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fallback) { return $fallback.FullName }
    return $null
}
$msbuild = Find-MsBuild
if (-not $msbuild) { throw "MSBuild not found (install VS Build Tools with the .NET + WinAppSDK workloads)" }
$proj = Join-Path $root "src\Rally.App\Rally.App.csproj"
# Publish into a clean directory so files from earlier builds cannot ship.
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
& $msbuild $proj /t:Publish /p:Configuration=Release /p:RuntimeIdentifier=$rid `
    /p:SelfContained=true /p:Platform=$platform /p:Version=$Version "/p:PublishDir=$out\" /restore
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
    Write-Host "The self-signed certificate identifies this local build; SmartScreen reputation warnings may still appear."
}

if (Test-Path $zip) { Remove-Item $zip }
$native = Join-Path $out "libvlc\$rid\libvlc.dll"
if (-not (Test-Path $native)) { throw "native VLC runtime missing for $rid" }
if (-not (Test-Path (Join-Path $out 'Assets\rally_wordmark.png'))) { throw 'Rally artwork missing' }
foreach ($resource in @('Rally.App.pri', 'App.xbf', 'MainWindow.xbf')) {
    if (-not (Test-Path (Join-Path $out $resource))) { throw "Compiled WinUI resource missing: $resource" }
}
foreach ($page in Get-ChildItem (Join-Path $root 'src\Rally.App\Views') -Filter '*.xaml') {
    $resource = Join-Path $out ("Views\" + $page.BaseName + '.xbf')
    if (-not (Test-Path $resource)) { throw "Compiled WinUI page missing: $($page.BaseName)" }
}
@"
Rally $Version for Windows ($Arch)
Extract this entire folder before launching Rally.App.exe.
Windows 10 1809 or newer is required. All runtimes are bundled.
Connect your own Stremio addon, Stalker/Ministra, Xtream, or M3U playlist in Settings.
Keyboard: Tab/Shift+Tab, arrows, Enter, Space to pause, Escape to return, F11 fullscreen.
The portable package is unsigned unless you explicitly signed your local build.
Preferences are stored in your Windows account's LocalAppData/Rally folder.
"@ | Set-Content (Join-Path $out 'START-HERE.txt')
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path $zip -Leaf)" | Set-Content "$zip.sha256"
Write-Host "DONE: $zip"
