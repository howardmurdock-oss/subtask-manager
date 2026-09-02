$ErrorActionPreference = 'Stop'

$snapDir = 'F:\subTask Manager\Snapshots'
New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$zipPath = "$snapDir\Snapshot_PreChanges_$timestamp.zip"

Write-Host "==> Creating timestamped snapshot zip at: $zipPath"
Compress-Archive -Path 'lib', 'test', 'linux', 'windows', 'android', 'web', 'macos', 'pubspec.yaml', 'FUTURE_FEATURES.md', 'STEAM_DECK_GUIDE.md', 'README.md' -DestinationPath $zipPath -Force

$fileInfo = Get-Item $zipPath
$sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
Write-Host "[OK] Snapshot created successfully! File size: $sizeMB MB"
