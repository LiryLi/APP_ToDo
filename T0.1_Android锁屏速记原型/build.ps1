param(
    [string]$ProjectRoot = $PSScriptRoot,
    [string]$ToolchainRoot = 'C:\Users\admin\AppData\Local\T01AndroidToolchain'
)
$ErrorActionPreference = 'Stop'
$createdSubst = $false
if ($ProjectRoot -match '[^\x00-\x7F]') {
    if (-not (Test-Path -LiteralPath 'R:\')) {
        subst R: $ProjectRoot
        $createdSubst = $true
    }
    $manifestProbe = 'R:\app\src\main\AndroidManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestProbe)) {
        throw 'R: is unavailable or points to another project. Free R: or pass -ProjectRoot with an ASCII path.'
    }
    if ([IO.File]::ReadAllText($manifestProbe) -notmatch 'package="com\.liry\.todo\.locknote"') {
        throw 'R: points to a different Android project. Free R: before building this project.'
    }
    $ProjectRoot = 'R:\'
}
$jdk = Join-Path $ToolchainRoot 'jdk'
$sdk = Join-Path $ToolchainRoot 'sdk'
$buildTools = Join-Path $sdk 'build-tools\35.0.0'
$androidJar = Join-Path $sdk 'platforms\android-35\android.jar'
$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;$buildTools;$env:PATH"
function Invoke-Native([string]$Name, [string]$Exe, [string[]]$Arguments) {
    Write-Output "==> $Name"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}
foreach ($required in @((Join-Path $jdk 'bin\javac.exe'), (Join-Path $buildTools 'aapt2.exe'),
    (Join-Path $buildTools 'd8.bat'), (Join-Path $buildTools 'apksigner.bat'), $androidJar)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required build tool missing: $required" }
}
$build = Join-Path $ProjectRoot 'build\manual'
$compiled = Join-Path $build 'compiled-res.zip'
$baseApk = Join-Path $build 'base.apk'
$unsignedApk = Join-Path $build 'unsigned.apk'
$alignedApk = Join-Path $build 'aligned.apk'
$generated = Join-Path $build 'generated'
$classes = Join-Path $build 'classes'
$dex = Join-Path $build 'dex'
$dist = Join-Path $ProjectRoot 'dist'
$outputApk = Join-Path $dist 'locknote-t01-demo.apk'
$keystore = Join-Path $build 'debug.keystore'
New-Item -ItemType Directory -Path $build, $generated, $classes, $dex, $dist -Force | Out-Null
Invoke-Native 'Compile resources' (Join-Path $buildTools 'aapt2.exe') @(
    'compile', '--dir', (Join-Path $ProjectRoot 'app\src\main\res'), '-o', $compiled)
Invoke-Native 'Link resources and manifest' (Join-Path $buildTools 'aapt2.exe') @(
    'link', '-o', $baseApk, '-I', $androidJar,
    '--manifest', (Join-Path $ProjectRoot 'app\src\main\AndroidManifest.xml'),
    '--java', $generated, '--min-sdk-version', '26', '--target-sdk-version', '35',
    '--version-code', '1', '--version-name', '0.1.0', $compiled)
$javaFiles = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'app\src\main\java') -Recurse -Filter '*.java'
    Get-ChildItem -LiteralPath $generated -Recurse -Filter '*.java') | ForEach-Object { $_.FullName }
Invoke-Native 'Compile Java sources' (Join-Path $jdk 'bin\javac.exe') (@(
    '-encoding', 'UTF-8', '-source', '8', '-target', '8',
    '-classpath', $androidJar, '-d', $classes) + $javaFiles)
$classFiles = Get-ChildItem -LiteralPath $classes -Recurse -Filter '*.class' | ForEach-Object { $_.FullName }
Invoke-Native 'Dex classes' (Join-Path $buildTools 'd8.bat') (@('--min-api', '26', '--output', $dex) + $classFiles)
Copy-Item -LiteralPath $baseApk -Destination $unsignedApk -Force
Push-Location $dex
try { Invoke-Native 'Add classes.dex to APK' (Join-Path $buildTools 'aapt.exe') @('add', $unsignedApk, 'classes.dex') }
finally { Pop-Location }
Invoke-Native 'Zipalign APK' (Join-Path $buildTools 'zipalign.exe') @('-f', '4', $unsignedApk, $alignedApk)
if (-not (Test-Path -LiteralPath $keystore)) {
    Invoke-Native 'Create debug signing key' (Join-Path $jdk 'bin\keytool.exe') @(
        '-genkeypair', '-keystore', $keystore, '-storepass', 'android',
        '-alias', 'androiddebugkey', '-keypass', 'android',
        '-dname', 'CN=LockNote Demo,O=Local Prototype,C=CN',
        '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000')
}
Invoke-Native 'Sign APK' (Join-Path $buildTools 'apksigner.bat') @(
    'sign', '--ks', $keystore, '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
    '--out', $outputApk, $alignedApk)
Invoke-Native 'Verify APK signature' (Join-Path $buildTools 'apksigner.bat') @(
    'verify', '--verbose', '--print-certs', $outputApk)
Invoke-Native 'Verify zip alignment' (Join-Path $buildTools 'zipalign.exe') @('-c', '4', $outputApk)
Invoke-Native 'Inspect APK package' (Join-Path $buildTools 'aapt.exe') @('dump', 'badging', $outputApk)
$apk = Get-Item -LiteralPath $outputApk
$hash = Get-FileHash -LiteralPath $outputApk -Algorithm SHA256
Write-Output "APK_READY=$($apk.FullName)"
Write-Output "APK_BYTES=$($apk.Length)"
Write-Output "APK_SHA256=$($hash.Hash)"