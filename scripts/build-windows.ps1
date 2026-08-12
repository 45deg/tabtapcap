$ErrorActionPreference = "Stop"

$pnpm = (Get-Command pnpm.cmd -ErrorAction Stop).Source
$node = (Get-Command node.exe -ErrorAction Stop).Source
$workspace = Split-Path -Parent $PSScriptRoot
$mappingRoot = [System.IO.Path]::GetFullPath($env:USERPROFILE)
$drive = $null

foreach ($letter in @("T", "U", "V", "W", "X", "Y", "Z")) {
    if (-not (Test-Path -LiteralPath "${letter}:\")) {
        $drive = "${letter}:"
        break
    }
}
if (-not $drive) {
    throw "A free drive letter is required to keep Vulkan build paths below the Windows limit."
}

& subst $drive $mappingRoot
if ($LASTEXITCODE -ne 0) {
    throw "Failed to map $drive to $mappingRoot."
}

try {
    $env:CARGO_TARGET_DIR = "$drive\.tabtapcap-build"
    . (Join-Path $PSScriptRoot "windows-env.ps1")
    $env:PATH = "$(Split-Path -Parent $node);$(Split-Path -Parent $pnpm);$env:PATH"
    & $pnpm --dir $workspace tauri:build
    if ($LASTEXITCODE -ne 0) {
        throw "Windows application build failed."
    }
} finally {
    & subst $drive /d
}

$outputRoot = Join-Path $mappingRoot ".tabtapcap-build\release"
$installer = Get-ChildItem -LiteralPath (Join-Path $outputRoot "bundle\nsis") -Filter "TabTapCap_*_x64-setup.exe" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
Write-Host "Windows Vulkan build completed."
Write-Host "Application: $(Join-Path $outputRoot 'tabtapcap.exe')"
Write-Host "Installer:   $installer"
Write-Warning "The workspace target\release directory may contain an older CPU-only build. Use the paths above."
