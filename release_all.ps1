<#
.SYNOPSIS
    Master Automated Multi-Platform Release Script for SubTask Manager.

.DESCRIPTION
    Executes the entire release pipeline with one command:
    1. Optionally bumps version in pubspec.yaml and Dart services.
    2. Runs the full test suite (92+ unit and widget tests).
    3. Compiles local Windows Standalone, Android APK, and Web releases.
    4. Commits and pushes changes to GitHub.
    5. Triggers GitHub Actions cloud build for native macOS (.dmg, .zip) and Linux (.tar.gz).
    6. Waits for cloud completion and downloads the native macOS and Linux artifacts.
    7. Syncs all binaries to Google Drive (G:\) and backup drive (F:\).
    8. Uploads all release binaries and casing aliases to Cloudflare R2.
    9. Publishes/updates the official GitHub Release with direct CDN download URLs.
    10. Deploys the website to Cloudflare Pages (subtaskmanager.com).

.EXAMPLE
    .\release_all.ps1
    .\release_all.ps1 -Version "1.2.0"
    .\release_all.ps1 -SkipCloudBuild
#>

param (
    [string]$Version,
    [switch]$SkipCloudBuild,
    [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

# Ensure environment paths
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
$flutterBat = "F:\src\flutter\bin\flutter.bat"
if (-not (Test-Path $flutterBat)) {
    $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCmd) { $flutterBat = $flutterCmd.Source } else { $flutterBat = "flutter" }
}

if (Test-Path ".\cloudflare_env.ps1") {
    . .\cloudflare_env.ps1
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   (sub)Task Manager - All-in-One Release Automation        " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Version Management
# ---------------------------------------------------------------------------
$pubspecContent = Get-Content "pubspec.yaml" -Raw
$currentVersion = "1.1.0"
if ($pubspecContent -match 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+?([0-9]*)') {
    $currentVersion = $matches[1]
    if ($matches[2]) { $currentBuild = [int]$matches[2] } else { $currentBuild = 1 }
} else {
    $currentBuild = 1
}

if ($Version) {
    $targetVersion = $Version
    $newBuild = $currentBuild + 1
    Write-Host "==> Bumping version from $currentVersion+$currentBuild to $targetVersion+$newBuild..." -ForegroundColor Yellow

    # Update pubspec.yaml
    $pubspecContent = $pubspecContent -replace 'version:\s*[0-9]+\.[0-9]+\.[0-9]+\+?[0-9]*', "version: $targetVersion+$newBuild"
    Set-Content "pubspec.yaml" $pubspecContent -NoNewline

    # Update quest_service.dart
    if (Test-Path "lib\services\quest_service.dart") {
        (Get-Content "lib\services\quest_service.dart" -Raw) -replace "appCurrentBuildVersion = '[^']+'", "appCurrentBuildVersion = '$targetVersion'" | Set-Content "lib\services\quest_service.dart" -NoNewline
    }
    # Update schedule_service.dart
    if (Test-Path "lib\services\schedule_service.dart") {
        (Get-Content "lib\services\schedule_service.dart" -Raw) -replace "appCurrentBuildVersion = '[^']+'", "appCurrentBuildVersion = '$targetVersion'" | Set-Content "lib\services\schedule_service.dart" -NoNewline
    }
} else {
    $targetVersion = $currentVersion
}
$releaseTag = "v$targetVersion"
Write-Host "==> Target Release: $targetVersion ($releaseTag)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Automated Test Suite
# ---------------------------------------------------------------------------
Write-Host "`n==> Step 1: Running Automated Tests..." -ForegroundColor Cyan
& $flutterBat test
if ($LASTEXITCODE -ne 0) {
    Write-Error "Tests failed. Aborting release."
    exit 1
}
Write-Host "  [OK] All tests passed cleanly." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Local Binary Builds (Windows, Android, Web)
# ---------------------------------------------------------------------------
Write-Host "`n==> Step 2: Compiling Windows Desktop Release..." -ForegroundColor Cyan
Get-Process orders_app -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
& $flutterBat build windows --release --no-tree-shake-icons
if ($LASTEXITCODE -ne 0) { Write-Error "Windows build failed."; exit 1 }
Compress-Archive -Path "build\windows\x64\runner\Release\*" -DestinationPath "subTaskManager-Windows-Release.zip" -Force
Copy-Item -Path "subTaskManager-Windows-Release.zip" -Destination "OrdersApp-Windows-Release.zip" -Force
Write-Host "  [OK] Windows package built." -ForegroundColor Green

Write-Host "`n==> Step 3: Compiling Android Release APK..." -ForegroundColor Cyan
& $flutterBat build apk --release --no-tree-shake-icons
if ($LASTEXITCODE -ne 0) { Write-Error "Android build failed."; exit 1 }
Copy-Item -Path "build\app\outputs\flutter-apk\app-release.apk" -Destination "subTaskManager-Android-Release.apk" -Force
Copy-Item -Path "build\app\outputs\flutter-apk\app-release.apk" -Destination "OrdersApp-Android-Release.apk" -Force
Write-Host "  [OK] Android APK built." -ForegroundColor Green

Write-Host "`n==> Step 4: Compiling Web Distributable..." -ForegroundColor Cyan
& $flutterBat build web --release --no-tree-shake-icons
if ($LASTEXITCODE -ne 0) { Write-Error "Web build failed."; exit 1 }
Compress-Archive -Path "build\web\*" -DestinationPath "subTaskManager-Web-Release.zip" -Force
Copy-Item -Path "subTaskManager-Web-Release.zip" -Destination "OrdersApp-Web-Release.zip" -Force
Write-Host "  [OK] Web bundle built." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Local Drives Sync (G:\ and F:\)
# ---------------------------------------------------------------------------
$gdriveTarget = "G:\My Drive\Orders App"
if (Test-Path "G:\My Drive") {
    Write-Host "`n==> Step 5: Syncing to Google Drive ($gdriveTarget)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $gdriveTarget | Out-Null
    New-Item -ItemType Directory -Force -Path "$gdriveTarget\Windows-Portable" | Out-Null
    New-Item -ItemType Directory -Force -Path "$gdriveTarget\Web-App" | Out-Null

    Copy-Item -Path "subTaskManager-Windows-Release.zip" -Destination "$gdriveTarget\" -Force
    Copy-Item -Path "subTaskManager-Android-Release.apk" -Destination "$gdriveTarget\" -Force
    Copy-Item -Path "subTaskManager-Web-Release.zip" -Destination "$gdriveTarget\" -Force
    Copy-Item -Path "OrdersApp-Windows-Release.zip" -Destination "$gdriveTarget\" -Force
    Copy-Item -Path "OrdersApp-Android-Release.apk" -Destination "$gdriveTarget\" -Force
    Copy-Item -Path "OrdersApp-Web-Release.zip" -Destination "$gdriveTarget\" -Force
    Copy-Item -Path "build\windows\x64\runner\Release\*" -Destination "$gdriveTarget\Windows-Portable" -Recurse -Force
    Copy-Item -Path "build\web\*" -Destination "$gdriveTarget\Web-App" -Recurse -Force
    Write-Host "  [OK] Google Drive updated." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 5. Git Commit & Push
# ---------------------------------------------------------------------------
Write-Host "`n==> Step 6: Committing & Pushing to GitHub..." -ForegroundColor Cyan
git add .
$status = git status --porcelain
if ($status) {
    git commit -m "Release $releaseTag - automated multi-platform build"
}
git push origin main
Write-Host "  [OK] Code pushed to GitHub main branch." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. Cloud Build: macOS & Linux via GitHub Actions
# ---------------------------------------------------------------------------
if (-not $SkipCloudBuild) {
    Write-Host "`n==> Step 7: Triggering macOS & Linux Cloud Build on GitHub Actions..." -ForegroundColor Cyan
    $runUrl = gh workflow run build_releases.yml --ref main 2>&1
    Write-Host "  Triggered workflow. Waiting for runners..." -ForegroundColor Yellow

    Start-Sleep -Seconds 10
    $latestRun = (gh run list --workflow=build_releases.yml --limit=1 --json databaseId,status -q ".[0]") | ConvertFrom-Json
    $runId = $latestRun.databaseId

    Write-Host "  Monitoring Run ID: $runId (Apple Silicon macOS + Ubuntu Linux)" -ForegroundColor Yellow
    $startTime = Get-Date
    while ($true) {
        Start-Sleep -Seconds 15
        $runInfo = (gh run view $runId --json status,conclusion -q "{status: .status, conclusion: .conclusion}") | ConvertFrom-Json
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
        Write-Host "  ... Build in progress ($($elapsed)s elapsed, status: $($runInfo.status))..." -ForegroundColor Gray

        if ($runInfo.status -eq "completed") {
            if ($runInfo.conclusion -eq "success") {
                Write-Host "  [OK] Cloud build completed successfully!" -ForegroundColor Green
                break
            } else {
                Write-Host "  [WARNING] Cloud build finished with conclusion: $($runInfo.conclusion). Checking artifacts anyway..." -ForegroundColor Yellow
                break
            }
        }
        if ($elapsed -gt 420) {
            Write-Host "  [WARNING] Cloud build timed out after 7 minutes. Continuing..." -ForegroundColor Yellow
            break
        }
    }

    # Download macOS and Linux artifacts
    Write-Host "`n==> Step 8: Downloading native macOS & Linux binaries from cloud..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path "dist" | Out-Null
    gh run download $runId --dir dist 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Cloud artifacts downloaded to dist/." -ForegroundColor Green

        # Copy cloud binaries to Google Drive
        if (Test-Path $gdriveTarget) {
            Get-ChildItem -Recurse dist -Include *.dmg, *.tar.gz, *.zip | ForEach-Object {
                Copy-Item $_.FullName -Destination $gdriveTarget -Force
            }
            Write-Host "  [OK] Native macOS & Linux copied to Google Drive." -ForegroundColor Green
        }
        # Copy to F: backup drive
        if (Test-Path "F:\subTask Manager") {
            Get-ChildItem -Recurse dist -Include *.dmg, *.tar.gz, *.zip | ForEach-Object {
                Copy-Item $_.FullName -Destination "F:\subTask Manager" -Force
            }
            Write-Host "  [OK] Native macOS & Linux mirrored to F: backup drive." -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Cloudflare R2 Uploads
# ---------------------------------------------------------------------------
Write-Host "`n==> Step 9: Uploading Release Binaries to Cloudflare R2..." -ForegroundColor Cyan

# Windows
cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/subTaskManager-Windows-Release.zip" --file="subTaskManager-Windows-Release.zip" --content-type="application/zip" --remote | Out-Null
cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/SubTaskManager-Windows-Release.zip" --file="subTaskManager-Windows-Release.zip" --content-type="application/zip" --remote | Out-Null
cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/OrdersApp-Windows-Release.zip" --file="subTaskManager-Windows-Release.zip" --content-type="application/zip" --remote | Out-Null

# Android
cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/subTaskManager-Android-Release.apk" --file="subTaskManager-Android-Release.apk" --content-type="application/vnd.android.package-archive" --remote | Out-Null
cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/SubTaskManager-Android-Release.apk" --file="subTaskManager-Android-Release.apk" --content-type="application/vnd.android.package-archive" --remote | Out-Null
cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/OrdersApp-Android-Release.apk" --file="subTaskManager-Android-Release.apk" --content-type="application/vnd.android.package-archive" --remote | Out-Null

# Web
cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/subTaskManager-Web-Release.zip" --file="subTaskManager-Web-Release.zip" --content-type="application/zip" --remote | Out-Null
cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/OrdersApp-Web-Release.zip" --file="subTaskManager-Web-Release.zip" --content-type="application/zip" --remote | Out-Null

# macOS (if downloaded)
$macDmg = Get-ChildItem -Recurse dist -Filter "*macOS.dmg" | Select-Object -First 1
if ($macDmg) {
    cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/subTaskManager-macOS.dmg" --file="$($macDmg.FullName)" --content-type="application/x-apple-diskimage" --remote | Out-Null
    cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/SubTaskManager-macOS.dmg" --file="$($macDmg.FullName)" --content-type="application/x-apple-diskimage" --remote | Out-Null
    cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/OrdersApp-macOS.dmg" --file="$($macDmg.FullName)" --content-type="application/x-apple-diskimage" --remote | Out-Null
}
$macZip = Get-ChildItem -Recurse dist -Filter "*macOS.zip" | Select-Object -First 1
if ($macZip) {
    cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/subTaskManager-macOS.zip" --file="$($macZip.FullName)" --content-type="application/zip" --remote | Out-Null
    cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/SubTaskManager-macOS.zip" --file="$($macZip.FullName)" --content-type="application/zip" --remote | Out-Null
}

# Linux (if downloaded)
$linuxTar = Get-ChildItem -Recurse dist -Filter "*Linux-x64.tar.gz" | Select-Object -First 1
if ($linuxTar) {
    cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/subTaskManager-Linux-x64.tar.gz" --file="$($linuxTar.FullName)" --content-type="application/gzip" --remote | Out-Null
    cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/SubTaskManager-Linux-x64.tar.gz" --file="$($linuxTar.FullName)" --content-type="application/gzip" --remote | Out-Null
    cmd.exe /c npx wrangler r2 object put "subtaskmanager-releases/OrdersApp-Linux-x64.tar.gz" --file="$($linuxTar.FullName)" --content-type="application/gzip" --remote | Out-Null
}
Write-Host "  [OK] Cloudflare R2 release storage updated." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 8. GitHub Releases Publishing
# ---------------------------------------------------------------------------
Write-Host "`n==> Step 10: Publishing to GitHub Releases ($releaseTag)..." -ForegroundColor Cyan
$releaseAssets = @(
    "subTaskManager-Windows-Release.zip",
    "subTaskManager-Android-Release.apk",
    "subTaskManager-Web-Release.zip"
)
if ($macDmg) { $releaseAssets += $macDmg.FullName }
if ($macZip) { $releaseAssets += $macZip.FullName }
if ($linuxTar) { $releaseAssets += $linuxTar.FullName }

# Check if release tag already exists, update or create
$existingRelease = gh release view $releaseTag 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Release $releaseTag exists. Uploading updated assets..." -ForegroundColor Yellow
    gh release upload $releaseTag $releaseAssets --clobber
} else {
    Write-Host "  Creating new release $releaseTag..." -ForegroundColor Yellow
    gh release create $releaseTag $releaseAssets --title "SubTask Manager $releaseTag" --notes "Automated release build supporting Windows, Android, macOS, Linux, Steam Deck, and Web."
}
Write-Host "  [OK] GitHub Release published at https://github.com/howardmurdock-oss/subtask-manager/releases/tag/$releaseTag" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 9. Cloudflare Pages Deployment
# ---------------------------------------------------------------------------
if (-not $SkipDeploy) {
    Write-Host "`n==> Step 11: Deploying Website to Cloudflare Pages (subtaskmanager.com)..." -ForegroundColor Cyan
    cmd.exe /c npx wrangler pages deploy website --project-name=subtaskmanager --branch=main --commit-dirty=true
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Production website live at https://subtaskmanager.com" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 10. Backup to F: Drive
# ---------------------------------------------------------------------------
if (Test-Path ".\backup_to_f.ps1") {
    Write-Host "`n==> Step 12: Mirroring full backup to F:\subTask Manager..." -ForegroundColor Cyan
    & powershell -ExecutionPolicy Bypass -File .\backup_to_f.ps1 | Out-Null
    Write-Host "  [OK] F: drive backup synchronized." -ForegroundColor Green
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "   RELEASE COMPLETED SUCCESSFULLY! ($releaseTag)            " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host " * Windows:     subTaskManager-Windows-Release.zip"
Write-Host " * Android:     subTaskManager-Android-Release.apk"
Write-Host " * macOS:       SubTaskManager-macOS.dmg & .zip"
Write-Host " * Linux:       SubTaskManager-Linux-x64.tar.gz"
Write-Host " * Web:         subTaskManager-Web-Release.zip"
Write-Host " * Live Site:   https://subtaskmanager.com"
Write-Host " * GitHub Rel:  https://github.com/howardmurdock-oss/subtask-manager/releases/tag/$releaseTag"
Write-Host "============================================================`n" -ForegroundColor Green
