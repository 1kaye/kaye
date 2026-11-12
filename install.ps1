$ErrorActionPreference = "Stop"

Write-Host "[kaye installer] Building kaye release binary..."
cargo build --release

$InstallDir = Join-Path $HOME ".local\bin"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}

$BinarySource = Join-Path (Get-Location) "target\release\kaye.exe"
$BinaryDest = Join-Path $InstallDir "kaye.exe"
Copy-Item -Path $BinarySource -Destination $BinaryDest -Force

Write-Host "[kaye installer] Installed 'kaye.exe' to $BinaryDest"

$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$UserPath;$InstallDir", "User")
    $env:Path = "$env:Path;$InstallDir"
    Write-Host "[kaye installer] Added $InstallDir to your User PATH."
}

Write-Host "[kaye installer] Setup complete. Restart your terminal and run 'kaye --help'."
