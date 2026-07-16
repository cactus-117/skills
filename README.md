# TikTok / Instagram 工具台技能包

这是一个可导入 Codex 的本地网页工具台技能包，包含 TikTok 和 Instagram 两个工作区。

## 功能

- TikTok 视频链接扒取：输入文案和一张或多张产品图，导出视频链接 Excel，并带历史文件。
- TikTok 主页视频数据分析：输入主页链接和数量，导出数据分析 Excel，可选择生成图表。
- TikTok 视频文件提取：输入 TikTok 视频链接，导出 MP4 文件，并带历史文件。
- Instagram 视频链接扒取：输入文案和产品图，导出视频链接 Excel，并带历史文件。
- Instagram 主页视频数据分析：输入主页链接和数量，导出数据分析 Excel，可选择生成图表。
- Instagram 视频文件提取：输入 Instagram Reel/视频链接，导出无水印 MP4 文件，并带历史文件。

## 安装到 Codex

把仓库里的 `tiktok-tools-web-suite` 文件夹复制到 Codex skills 目录：

Windows:

```powershell
%USERPROFILE%\.codex\skills\tiktok-tools-web-suite
```

macOS:

```bash
~/.codex/skills/tiktok-tools-web-suite
```

## 启动

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\tiktok-tools-web-suite\scripts\start-tiktok-tools-suite.ps1"
```

macOS:

```bash
bash ~/.codex/skills/tiktok-tools-web-suite/scripts/start-tiktok-tools-suite-macos.sh
```

启动脚本会输出本地访问地址，默认是 `http://localhost:8788/`，如果端口被占用会自动换到下一个端口。

## 依赖

Windows 可把 `yt-dlp.exe` 放到：

```text
tiktok-tools-web-suite/scripts/tools/yt-dlp.exe
```

macOS 建议安装：

```bash
brew install --cask powershell
brew install yt-dlp
```

## 说明

工具台只处理公开页面和用户主动输入的链接。TikTok / Instagram 可能出现限流、403、429、页面改版或需要登录的情况；这类情况通常需要稍后重试、换公开主页链接，或在本机浏览器保持登录后再尝试相关下载功能。
