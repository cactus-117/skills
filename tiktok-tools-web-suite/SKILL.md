---
name: tiktok-tools-web-suite
description: Complete local TikTok and Instagram web tool suite with a visual browser UI. Use when the user wants to start, package, update, or troubleshoot a TikTok / Instagram 工具台 that includes TikTok 视频链接扒取, TikTok 主页视频数据分析, TikTok 视频文件提取, Instagram 视频链接扒取, Instagram 主页视频数据分析, and Instagram 视频文件提取.
---

# TikTok / Instagram Tools Web Suite

Use this skill to run, package, or update the bundled local web app in `scripts/tiktok-tools-web/`.

## Capabilities

- `TikTok 视频链接扒取`: users enter text and upload one or more product images; the app returns TikTok video links in an `.xlsx` file. Repeated identical text/image inputs avoid links returned before.
- `TikTok 主页视频数据分析`: users enter a TikTok profile URL, video count, and chart toggle; the app returns an Excel data analysis file and can include a chart.
- `TikTok 视频文件提取`: users enter a TikTok video URL; the app returns a downloadable `.mp4` file.
- `Instagram 视频链接扒取`: users enter text and upload one or more product images; the app returns Instagram video links in an `.xlsx` file.
- `Instagram 主页视频数据分析`: users enter an Instagram profile URL, video count, and chart toggle; the app returns an Excel data analysis file and can include a chart.
- `Instagram 视频文件提取`: users enter an Instagram Reel/video URL; the app returns a downloadable no-watermark `.mp4` file.
- Each module has a separate `历史文件` page with download and delete.
- The first screen is the usable web UI, not a landing page.

## Import And Start

Place this skill folder at:

- Windows: `%USERPROFILE%\.codex\skills\tiktok-tools-web-suite`
- macOS: `~/.codex/skills/tiktok-tools-web-suite`

Start on Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\tiktok-tools-web-suite\scripts\start-tiktok-tools-suite.ps1"
```

Start on macOS:

```bash
bash ~/.codex/skills/tiktok-tools-web-suite/scripts/start-tiktok-tools-suite-macos.sh
```

The start helper launches the main web app on `http://localhost:8788/` or the next free port and prints JSON with the actual URL and process id.

On macOS, install PowerShell 7 if `pwsh` is missing. Install `yt-dlp` if the MP4 extraction modules are needed:

```bash
brew install --cask powershell
brew install yt-dlp
```

## Bundled Files

- Main visual web app: `scripts/tiktok-tools-web/`
- Internal profile data service used by the main app: `scripts/profile-data-web/`
- Optional tools folder: `scripts/tools/`
- Main start script: `scripts/start-tiktok-tools-suite.ps1`
- macOS helper: `scripts/start-tiktok-tools-suite-macos.sh`

The main app creates runtime folders next to the scripts as needed: `exports/`, `profile_exports/`, `instagram_exports/`, `instagram_profile_exports/`, `data/`, `downloads/tiktok/`, and `downloads/instagram/`.

## Update Workflow

Edit these files for visual/UI changes:

- `scripts/tiktok-tools-web/index.html`
- `scripts/tiktok-tools-web/styles.css`
- `scripts/tiktok-tools-web/app.js`
- History pages: `history.html`, `profile-history.html`, `video-file-history.html`, `instagram-link-history.html`, `instagram-profile-history.html`, `instagram-history.html`, `history.js`, `file-history.js`

Edit `scripts/tiktok-tools-web/server.ps1` for:

- TikTok/Instagram link scraping API and Excel output
- dedupe/history behavior
- profile data analysis
- MP4 extraction and download routes
- history download/delete routes

Edit `scripts/profile-data-web/server.ps1` only when changing the internal profile-video Excel format or chart generation internals.

Keep the six modules independent. When the user asks to change one module, do not modify the other modules unless the request explicitly requires it.

## Validation

After changes:

1. Parse-check both PowerShell services.
2. Start the web tool and request the main page.
3. Confirm the page contains all six module headings.
4. For visual changes, verify with a browser screenshot.
5. For backend changes, test the affected endpoint and its matching history page.

## Operational Notes

- The tool uses public TikTok/Instagram-facing data and local downloads. Do not claim private analytics access.
- TikTok, Instagram, and upstream services may rate-limit, block, require login, or change responses. If extraction fails, explain that the user can retry later or provide a different public URL.
- The MP4 modules use bundled `scripts/tools/yt-dlp.exe` on Windows when present, otherwise system `yt-dlp`. On macOS use system `yt-dlp`.
