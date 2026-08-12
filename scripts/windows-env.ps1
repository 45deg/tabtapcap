$ErrorActionPreference = "Stop"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio Installer (vswhere.exe) was not found."
}

$visualStudio = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) {
    throw "Visual Studio with the C++ x64/x86 build tools was not found."
}

$developerCommand = Join-Path $visualStudio "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path -LiteralPath $developerCommand)) {
    throw "Visual Studio Developer Command Prompt was not found: $developerCommand"
}
$developerEnvironment = & $env:ComSpec /d /s /c "`"$developerCommand`" -no_logo -arch=x64 -host_arch=x64 && set"
if ($LASTEXITCODE -ne 0) {
    throw "Visual Studio Developer Command Prompt initialization failed."
}
$importedNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($line in $developerEnvironment) {
    if ($line -match '^([^=]+)=(.*)$' -and $importedNames.Add($Matches[1])) {
        Set-Item -LiteralPath "Env:$($Matches[1])" -Value $Matches[2]
    }
}

$llvm = Join-Path $visualStudio "VC\Tools\Llvm\x64"
$libclang = Join-Path $llvm "bin\libclang.dll"
$clang = Join-Path $llvm "bin\clang.exe"
$cmake = Join-Path $visualStudio "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$ninja = Join-Path $visualStudio "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
foreach ($required in @($libclang, $clang, $cmake, $ninja)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required Windows build tool was not found: $required"
    }
}

$vulkanSdk = $env:VULKAN_SDK
if (-not $vulkanSdk) {
    $vulkanRoot = Join-Path $env:SystemDrive "VulkanSDK"
    $vulkanSdk = Get-ChildItem -LiteralPath $vulkanRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $vulkanSdk) {
    throw "Vulkan SDK was not found. Install the LunarG Vulkan SDK."
}
$vulkanSdk = [System.IO.Path]::GetFullPath($vulkanSdk)
$vulkanHeader = Join-Path $vulkanSdk "Include\vulkan\vulkan.h"
$vulkanLibrary = Join-Path $vulkanSdk "Lib\vulkan-1.lib"
$glslc = Join-Path $vulkanSdk "Bin\glslc.exe"
foreach ($required in @($vulkanHeader, $vulkanLibrary, $glslc)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required Vulkan SDK file was not found: $required"
    }
}
$env:VULKAN_SDK = $vulkanSdk

$msvc = Get-ChildItem (Join-Path $visualStudio "VC\Tools\MSVC") -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (-not $msvc -or -not $sdk) {
    throw "The MSVC headers or Windows SDK headers were not found."
}

$clangResource = & $clang -print-resource-dir
$includeDirectories = @(
    (Join-Path $clangResource "include"),
    (Join-Path $msvc.FullName "include"),
    (Join-Path $sdk.FullName "ucrt"),
    (Join-Path $sdk.FullName "shared"),
    (Join-Path $sdk.FullName "um"),
    (Join-Path $sdk.FullName "winrt")
)

$env:LIBCLANG_PATH = Split-Path -Parent $libclang
$env:BINDGEN_EXTRA_CLANG_ARGS = ($includeDirectories | ForEach-Object { "-isystem `"$_`"" }) -join " "
$env:CMAKE = $cmake
$env:CMAKE_GENERATOR = "Ninja"
$env:CMAKE_MAKE_PROGRAM = $ninja
if (-not $env:CARGO_TARGET_DIR) {
    $env:CARGO_TARGET_DIR = Join-Path $env:USERPROFILE ".tabtapcap-build"
}
$env:CMAKE_C_FLAGS_RELEASE = "/MT"
$env:CMAKE_CXX_FLAGS_RELEASE = "/MT"
$env:CMAKE_C_FLAGS_RELWITHDEBINFO = "/MT"
$env:CMAKE_CXX_FLAGS_RELWITHDEBINFO = "/MT"
if ($env:RUSTFLAGS -notmatch "target-feature=\+crt-static") {
    $env:RUSTFLAGS = (($env:RUSTFLAGS, "-C target-feature=+crt-static") | Where-Object { $_ }) -join " "
}

Write-Host "Configured Windows build tools from $visualStudio"
Write-Host "LIBCLANG_PATH=$env:LIBCLANG_PATH"
Write-Host "CMAKE=$env:CMAKE"
Write-Host "CMAKE_GENERATOR=$env:CMAKE_GENERATOR"
Write-Host "CARGO_TARGET_DIR=$env:CARGO_TARGET_DIR"
Write-Host "VULKAN_SDK=$vulkanSdk"
