$ErrorActionPreference = 'Stop'

$src = "c:\Users\howar\Documents\antigravity\Orders App"
$dst = "F:\subTask Manager"

Write-Host "==> Creating backup destination: $dst"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
New-Item -ItemType Directory -Force -Path "$dst\Releases" | Out-Null

Write-Host "==> Copying project source codebase..."
robocopy $src $dst /E /XD .git .dart_tool build .gradle .idea /XF *.log *.tmp /NDL /NFL /NP /NJH /NJS

# Robocopy exit codes 0-7 indicate success
if ($LASTEXITCODE -gt 7) {
    Write-Error "Robocopy encountered an error (Code: $LASTEXITCODE)"
}

Write-Host "==> Copying release binaries..."
$apkSrc = "$src\build\app\outputs\flutter-apk\app-release.apk"
if (Test-Path $apkSrc) {
    Copy-Item $apkSrc -Destination "$dst\Releases\app-release.apk" -Force
    Write-Host "  [OK] Copied Android Release APK (app-release.apk)"
}

$winSrc = "$src\build\windows\x64\runner\Release"
if (Test-Path $winSrc) {
    robocopy $winSrc "$dst\Releases\Windows" /E /NDL /NFL /NP /NJH /NJS
    Write-Host "  [OK] Copied Windows Release Standalone bundle"
}

$webZipSrc = "$src\subTaskManager-Web-Release.zip"
if (Test-Path $webZipSrc) {
    Copy-Item $webZipSrc -Destination "$dst\subTaskManager-Web-Release.zip" -Force
    Copy-Item "$src\OrdersApp-Web-Release.zip" -Destination "$dst\OrdersApp-Web-Release.zip" -Force
    Write-Host "  [OK] Copied Web Distributable Archives"
}

Write-Host ""
Write-Host "==> Backup completed successfully at $dst!"
Write-Host "Contents of backup folder:"
Get-ChildItem -Path $dst | Select-Object Name, Mode, LastWriteTime | Format-Table -AutoSize
