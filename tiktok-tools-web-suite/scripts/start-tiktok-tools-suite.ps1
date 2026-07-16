param(
  [int]$Port = 8788
)

$toolStart = Join-Path $PSScriptRoot "tiktok-tools-web\start.ps1"
& $toolStart -Port $Port
