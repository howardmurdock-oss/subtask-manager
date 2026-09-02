param (
    [string]$Version,
    [switch]$LocalOnly,
    [switch]$SkipCloudBuild,
    [switch]$SkipDeploy
)

if (-not $LocalOnly) {
    & powershell -ExecutionPolicy Bypass -File .\release_all.ps1 @PSBoundParameters
    exit $LASTEXITCODE
}

# Local-only build below:
Write-Host "==> Compiling Automated Tests..." -ForegroundColor Cyan
& "F:\src\flutter\bin\flutter.bat" test
if ($LASTEXITCODE -ne 0) {
    Write-Error "Tests failed. Aborting build."
    exit 1
}

Write-Host "==> Building Windows Standalone Release..." -ForegroundColor Cyan
Get-Process orders_app -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
& "F:\src\flutter\bin\flutter.bat" build windows --release --no-tree-shake-icons
Compress-Archive -Path "build\windows\x64\runner\Release\*" -DestinationPath "subTaskManager-Windows-Release.zip" -Force
Copy-Item -Path "subTaskManager-Windows-Release.zip" -Destination "OrdersApp-Windows-Release.zip" -Force

Write-Host "==> Building Android Release APK..." -ForegroundColor Cyan
& "F:\src\flutter\bin\flutter.bat" build apk --release --no-tree-shake-icons
Copy-Item -Path "build\app\outputs\flutter-apk\app-release.apk" -Destination "subTaskManager-Android-Release.apk" -Force
Copy-Item -Path "build\app\outputs\flutter-apk\app-release.apk" -Destination "OrdersApp-Android-Release.apk" -Force

Write-Host "==> Building Web Distributable (Cross-Platform Browser Release)..." -ForegroundColor Cyan
& "F:\src\flutter\bin\flutter.bat" build web --release --no-tree-shake-icons
Compress-Archive -Path "build\web\*" -DestinationPath "subTaskManager-Web-Release.zip" -Force
Copy-Item -Path "subTaskManager-Web-Release.zip" -Destination "OrdersApp-Web-Release.zip" -Force

$gdriveTarget = "G:\My Drive\Orders App"
if (Test-Path "G:\My Drive") {
    Write-Host "==> Syncing releases to Google Drive ($gdriveTarget)..." -ForegroundColor Green
    New-Item -ItemType Directory -Force -Path $gdriveTarget | Out-Null
    New-Item -ItemType Directory -Force -Path "$gdriveTarget\Windows-Portable" | Out-Null
    New-Item -ItemType Directory -Force -Path "$gdriveTarget\Web-App" | Out-Null

    Copy-Item -Path "subTaskManager-Windows-Release.zip" -Destination "$gdriveTarget\subTaskManager-Windows-Release.zip" -Force
    Copy-Item -Path "subTaskManager-Android-Release.apk" -Destination "$gdriveTarget\subTaskManager-Android-Release.apk" -Force
    Copy-Item -Path "subTaskManager-Web-Release.zip" -Destination "$gdriveTarget\subTaskManager-Web-Release.zip" -Force
    Copy-Item -Path "OrdersApp-Windows-Release.zip" -Destination "$gdriveTarget\OrdersApp-Windows-Release.zip" -Force
    Copy-Item -Path "OrdersApp-Android-Release.apk" -Destination "$gdriveTarget\OrdersApp-Android-Release.apk" -Force
    Copy-Item -Path "OrdersApp-Web-Release.zip" -Destination "$gdriveTarget\OrdersApp-Web-Release.zip" -Force
    Copy-Item -Path "build\windows\x64\runner\Release\*" -Destination "$gdriveTarget\Windows-Portable" -Recurse -Force
    Copy-Item -Path "build\web\*" -Destination "$gdriveTarget\Web-App" -Recurse -Force
    Write-Host "==> Successfully updated Google Drive!" -ForegroundColor Green
} else {
    Write-Host "==> Note: Google Drive (G:\) not mounted. Artifacts available locally." -ForegroundColor Yellow
}
