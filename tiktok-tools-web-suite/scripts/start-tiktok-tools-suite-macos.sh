#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 is required. Install it on macOS with: brew install --cask powershell"
  exit 1
fi

if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "Notice: MP4 extraction needs yt-dlp. Install it with: brew install yt-dlp"
fi

pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/start-tiktok-tools-suite.ps1" "$@"
