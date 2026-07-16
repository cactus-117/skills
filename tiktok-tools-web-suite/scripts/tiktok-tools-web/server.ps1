param(
  [int]$Port = 8788
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExportDir = Join-Path $Root "exports"
$ProfileExportDir = Join-Path $Root "profile_exports"
$InstagramLinkExportDir = Join-Path $Root "instagram_exports"
$InstagramProfileExportDir = Join-Path $Root "instagram_profile_exports"
$DataDir = Join-Path $Root "data"
$HistoryPath = Join-Path $DataDir "history.json"
$ProfileHistoryPath = Join-Path $DataDir "profile-history.json"
$VideoFileHistoryPath = Join-Path $DataDir "video-file-history.json"
$InstagramLinkHistoryPath = Join-Path $DataDir "instagram-link-history.json"
$InstagramProfileHistoryPath = Join-Path $DataDir "instagram-profile-history.json"
$InstagramHistoryPath = Join-Path $DataDir "instagram-history.json"
$WorkspaceRoot = Split-Path -Parent $Root
$BundledYtDlpPath = Join-Path $WorkspaceRoot "tools\yt-dlp.exe"
$YtDlpPath = $BundledYtDlpPath
$VideoDownloadDir = Join-Path $WorkspaceRoot "downloads\tiktok"
$InstagramDownloadDir = Join-Path $WorkspaceRoot "downloads\instagram"
$BundledProfileToolScript = Join-Path $WorkspaceRoot "profile-data-web\server.ps1"
$UserProfileToolScript = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE ".codex\skills\tiktok-video-data-extractor\scripts\tiktok-data-web\server.ps1" } else { "" }
$ProfileToolScript = if (Test-Path -LiteralPath $BundledProfileToolScript) {
  $BundledProfileToolScript
} elseif (-not [string]::IsNullOrWhiteSpace($UserProfileToolScript) -and (Test-Path -LiteralPath $UserProfileToolScript)) {
  $UserProfileToolScript
} else {
  $BundledProfileToolScript
}
$ProfileToolPort = 8765

New-Item -ItemType Directory -Force -Path $ExportDir | Out-Null
New-Item -ItemType Directory -Force -Path $ProfileExportDir | Out-Null
New-Item -ItemType Directory -Force -Path $InstagramLinkExportDir | Out-Null
New-Item -ItemType Directory -Force -Path $InstagramProfileExportDir | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $VideoDownloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $InstagramDownloadDir | Out-Null

function Get-PowerShellCommand {
  try {
    $current = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($current)) {
      return $current
    }
  } catch {}
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) { return $pwsh.Source }
  $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($powershell) { return $powershell.Source }
  throw "PowerShell runtime was not found. Install PowerShell 7 (pwsh) and try again."
}

function Get-YtDlpCommand {
  if (Test-Path -LiteralPath $BundledYtDlpPath) {
    return $BundledYtDlpPath
  }
  $ytDlp = Get-Command yt-dlp -ErrorAction SilentlyContinue
  if ($ytDlp) {
    return $ytDlp.Source
  }
  throw "Video download tool was not found. Install yt-dlp or place yt-dlp.exe in the bundled tools folder."
}

function Test-YtDlpAvailable {
  try {
    [void](Get-YtDlpCommand)
    return $true
  } catch {
    return $false
  }
}

function Send-Bytes {
  param($Context, [int]$Status, [string]$ContentType, [byte[]]$Bytes)
  $Context.Response.StatusCode = $Status
  $Context.Response.ContentType = $ContentType
  $Context.Response.Headers.Set("Access-Control-Allow-Origin", "*")
  $Context.Response.Headers.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
  $Context.Response.Headers.Set("Access-Control-Allow-Headers", "Content-Type")
  $Context.Response.Headers.Set("Access-Control-Expose-Headers", "Content-Disposition, X-Extracted-Count, X-Profile-Video-Count, X-Requested-Count")
  $Context.Response.ContentLength64 = $Bytes.Length
  $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $Context.Response.OutputStream.Close()
}

function Send-Text {
  param($Context, [int]$Status, [string]$ContentType, [string]$Text)
  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  Send-Bytes -Context $Context -Status $Status -ContentType $ContentType -Bytes $bytes
}

function Send-Json {
  param($Context, [int]$Status, $Object)
  $json = $Object | ConvertTo-Json -Depth 8
  Send-Text -Context $Context -Status $Status -ContentType "application/json; charset=utf-8" -Text $json
}

function Read-BodyText {
  param($Request)
  $memory = New-Object IO.MemoryStream
  $Request.InputStream.CopyTo($memory)
  return [Text.Encoding]::UTF8.GetString($memory.ToArray())
}

function Read-BodyJson {
  param($Request)
  $body = Read-BodyText -Request $Request
  if ([string]::IsNullOrWhiteSpace($body)) {
    return $null
  }
  return $body | ConvertFrom-Json
}

function Test-ProfileTool {
  param([int]$Port)
  try {
    $response = Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 2
    return ($response.StatusCode -eq 200)
  } catch {
    return $false
  }
}

function Ensure-ProfileTool {
  if (Test-ProfileTool -Port $ProfileToolPort) {
    return "http://localhost:$ProfileToolPort"
  }

  if (-not (Test-Path -LiteralPath $ProfileToolScript)) {
    throw "TikTok profile extractor service was not found."
  }

  $startArgs = @{
    FilePath = Get-PowerShellCommand
    ArgumentList = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $ProfileToolScript,
    "-Port",
    [string]$ProfileToolPort
    )
  }
  if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $startArgs.WindowStyle = "Hidden"
  }
  Start-Process @startArgs | Out-Null

  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-ProfileTool -Port $ProfileToolPort) {
      return "http://localhost:$ProfileToolPort"
    }
  }

  throw "TikTok profile extractor service did not start."
}

function Invoke-ProfileToolExtract {
  param([string]$Body)
  $baseUrl = Ensure-ProfileTool
  $request = [Net.HttpWebRequest]::Create("$baseUrl/api/extract")
  $request.Method = "POST"
  $request.ContentType = "application/json; charset=utf-8"
  $request.Timeout = 600000
  $request.ReadWriteTimeout = 600000
  $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
  $request.ContentLength = $bytes.Length
  $stream = $request.GetRequestStream()
  try {
    $stream.Write($bytes, 0, $bytes.Length)
  } finally {
    $stream.Dispose()
  }

  $response = $null
  try {
    $response = $request.GetResponse()
  } catch [Net.WebException] {
    $response = $_.Exception.Response
    if ($null -eq $response) {
      throw
    }
  }

  $memory = New-Object IO.MemoryStream
  try {
    $responseStream = $response.GetResponseStream()
    try {
      $responseStream.CopyTo($memory)
    } finally {
      $responseStream.Dispose()
    }
    $headers = @{}
    foreach ($name in @("Content-Disposition", "X-Extracted-Count", "X-Profile-Video-Count", "X-Requested-Count")) {
      $value = $response.Headers[$name]
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        $headers[$name] = $value
      }
    }
    return [pscustomobject]@{
      StatusCode = [int]$response.StatusCode
      ContentType = $response.ContentType
      Headers = $headers
      Bytes = $memory.ToArray()
    }
  } finally {
    $memory.Dispose()
    $response.Dispose()
  }
}

function Get-HistoryFromPath {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return @()
  }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @()
  }
  $parsed = $raw | ConvertFrom-Json
  if ($null -eq $parsed) {
    return @()
  }
  $names = @($parsed.PSObject.Properties | ForEach-Object { $_.Name })
  if ($names -contains "value") {
    $parsed = $parsed.value
  }
  return @($parsed | Where-Object { $null -ne $_ -and $_.fileName })
}

function Save-HistoryToPath {
  param([string]$Path, [array]$Items)
  $clean = @($Items | Where-Object { $null -ne $_ -and $_.fileName })
  $json = ConvertTo-Json -InputObject $clean -Depth 8
  if ([string]::IsNullOrWhiteSpace($json)) {
    $json = "[]"
  }
  Set-Content -LiteralPath $Path -Encoding UTF8 -Value $json
}

function Get-History {
  return Get-HistoryFromPath -Path $HistoryPath
}

function Save-History {
  param([array]$Items)
  Save-HistoryToPath -Path $HistoryPath -Items $Items
}

function Get-ProfileHistory {
  return Get-HistoryFromPath -Path $ProfileHistoryPath
}

function Save-ProfileHistory {
  param([array]$Items)
  Save-HistoryToPath -Path $ProfileHistoryPath -Items $Items
}

function Get-VideoFileHistory {
  return Get-HistoryFromPath -Path $VideoFileHistoryPath
}

function Save-VideoFileHistory {
  param([array]$Items)
  Save-HistoryToPath -Path $VideoFileHistoryPath -Items $Items
}

function Get-InstagramLinkHistory {
  return Get-HistoryFromPath -Path $InstagramLinkHistoryPath
}

function Save-InstagramLinkHistory {
  param([array]$Items)
  Save-HistoryToPath -Path $InstagramLinkHistoryPath -Items $Items
}

function Get-InstagramProfileHistory {
  return Get-HistoryFromPath -Path $InstagramProfileHistoryPath
}

function Save-InstagramProfileHistory {
  param([array]$Items)
  Save-HistoryToPath -Path $InstagramProfileHistoryPath -Items $Items
}

function Get-InstagramHistory {
  return Get-HistoryFromPath -Path $InstagramHistoryPath
}

function Save-InstagramHistory {
  param([array]$Items)
  Save-HistoryToPath -Path $InstagramHistoryPath -Items $Items
}

function Get-ContentType {
  param([string]$Path)
  switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { "text/html; charset=utf-8"; break }
    ".css" { "text/css; charset=utf-8"; break }
    ".js" { "application/javascript; charset=utf-8"; break }
    ".csv" { "text/csv; charset=utf-8"; break }
    ".mp4" { "video/mp4"; break }
    ".xlsx" { "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"; break }
    default { "application/octet-stream"; break }
  }
}

function ConvertTo-SafeFileName {
  param([string]$Value)
  $clean = $Value -replace '[\\/:*?"<>|]+', "_"
  $clean = $clean -replace '\s+', "_"
  $clean = $clean.Trim("_")
  if ($clean.Length -gt 36) {
    $clean = $clean.Substring(0, 36)
  }
  if ([string]::IsNullOrWhiteSpace($clean)) {
    return "video_links"
  }
  return $clean
}

function ConvertTo-StorageFileName {
  param([string]$Value, [string]$Default)
  $name = Split-Path -Leaf ([string]$Value)
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = $Default
  }
  $invalid = [IO.Path]::GetInvalidFileNameChars()
  $builder = New-Object Text.StringBuilder
  foreach ($char in $name.ToCharArray()) {
    if ($invalid -contains $char) {
      [void]$builder.Append("_")
    } else {
      [void]$builder.Append($char)
    }
  }
  $clean = $builder.ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($clean)) {
    $clean = $Default
  }
  if ($clean.Length -gt 120) {
    $extension = [IO.Path]::GetExtension($clean)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($clean)
    $maxBase = [Math]::Max(1, 120 - $extension.Length)
    $clean = $baseName.Substring(0, [Math]::Min($baseName.Length, $maxBase)) + $extension
  }
  return $clean
}

function Get-FileNameFromDisposition {
  param([string]$Disposition, [string]$Default)
  if ([string]::IsNullOrWhiteSpace($Disposition)) {
    return ConvertTo-StorageFileName -Value $Default -Default $Default
  }
  $utf8Match = [regex]::Match($Disposition, "filename\*=UTF-8''([^;]+)", [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($utf8Match.Success) {
    return ConvertTo-StorageFileName -Value ([Uri]::UnescapeDataString($utf8Match.Groups[1].Value)) -Default $Default
  }
  $asciiMatch = [regex]::Match($Disposition, 'filename="?([^";]+)"?', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($asciiMatch.Success) {
    return ConvertTo-StorageFileName -Value $asciiMatch.Groups[1].Value -Default $Default
  }
  return ConvertTo-StorageFileName -Value $Default -Default $Default
}

function Add-ProfileHistoryItem {
  param([byte[]]$Bytes, [hashtable]$Headers, [string]$ProfileUrl, [int]$RequestedCount, [bool]$GenerateChart)
  $id = Get-Date -Format "yyyyMMdd_HHmmss_fff"
  $fileName = Get-FileNameFromDisposition -Disposition ([string]$Headers["Content-Disposition"]) -Default "TikTok-profile-data.xlsx"
  $storedFileName = "${id}_$fileName"
  $filePath = Join-Path $ProfileExportDir $storedFileName
  [IO.File]::WriteAllBytes($filePath, $Bytes)

  $entry = [ordered]@{
    id = $id
    createdAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    fileName = $fileName
    storedFileName = $storedFileName
    size = $Bytes.Length
    profileUrl = $ProfileUrl
    requestedCount = $RequestedCount
    generateChart = $GenerateChart
    extractedCount = [string]$Headers["X-Extracted-Count"]
    profileVideoCount = [string]$Headers["X-Profile-Video-Count"]
    downloadUrl = "/profile-download/$id"
  }

  $history = New-Object System.Collections.Generic.List[object]
  $history.Add([pscustomobject]$entry) | Out-Null
  foreach ($item in @(Get-ProfileHistory)) {
    if ($null -ne $item -and $item.fileName -and ([string]$item.id) -ne $id) {
      $history.Add($item) | Out-Null
    }
  }
  Save-ProfileHistory -Items @($history | Select-Object -First 100)
  return [pscustomobject]$entry
}

function Add-InstagramProfileHistoryItem {
  param([byte[]]$Bytes, [hashtable]$Headers, [string]$ProfileUrl, [int]$RequestedCount, [bool]$GenerateChart, [string]$FileName)
  $id = Get-Date -Format "yyyyMMdd_HHmmss_fff"
  $fileName = ConvertTo-StorageFileName -Value $FileName -Default "Instagram-profile-data.xlsx"
  $storedFileName = "${id}_$fileName"
  $filePath = Join-Path $InstagramProfileExportDir $storedFileName
  [IO.File]::WriteAllBytes($filePath, $Bytes)

  $entry = [ordered]@{
    id = $id
    createdAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    fileName = $fileName
    storedFileName = $storedFileName
    size = $Bytes.Length
    profileUrl = $ProfileUrl
    requestedCount = $RequestedCount
    generateChart = $GenerateChart
    extractedCount = [string]$Headers["X-Extracted-Count"]
    profileVideoCount = [string]$Headers["X-Profile-Video-Count"]
    downloadUrl = "/instagram-profile-download/$id"
  }

  $history = New-Object System.Collections.Generic.List[object]
  $history.Add([pscustomobject]$entry) | Out-Null
  foreach ($item in @(Get-InstagramProfileHistory)) {
    if ($null -ne $item -and $item.fileName -and ([string]$item.id) -ne $id) {
      $history.Add($item) | Out-Null
    }
  }
  Save-InstagramProfileHistory -Items @($history | Select-Object -First 100)
  return [pscustomobject]$entry
}

function Add-VideoFileHistoryItem {
  param([string]$VideoUrl, [IO.FileInfo]$File)
  $id = Get-Date -Format "yyyyMMdd_HHmmss_fff"
  $entry = [ordered]@{
    id = $id
    createdAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    fileName = $File.Name
    storedFileName = $File.Name
    size = $File.Length
    videoUrl = $VideoUrl
    downloadUrl = "/video-download/$($File.Name)"
  }

  $history = New-Object System.Collections.Generic.List[object]
  $history.Add([pscustomobject]$entry) | Out-Null
  foreach ($item in @(Get-VideoFileHistory)) {
    if ($null -ne $item -and $item.fileName -and ([string]$item.storedFileName) -ne $File.Name) {
      $history.Add($item) | Out-Null
    }
  }
  Save-VideoFileHistory -Items @($history | Select-Object -First 100)
  return [pscustomobject]$entry
}

function Add-InstagramHistoryItem {
  param([string]$InstagramUrl, [IO.FileInfo]$File)
  $id = Get-Date -Format "yyyyMMdd_HHmmss_fff"
  $entry = [ordered]@{
    id = $id
    createdAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    fileName = $File.Name
    storedFileName = $File.Name
    size = $File.Length
    instagramUrl = $InstagramUrl
    downloadUrl = "/instagram-download/$($File.Name)"
  }

  $history = New-Object System.Collections.Generic.List[object]
  $history.Add([pscustomobject]$entry) | Out-Null
  foreach ($item in @(Get-InstagramHistory)) {
    if ($null -ne $item -and $item.fileName -and ([string]$item.storedFileName) -ne $File.Name) {
      $history.Add($item) | Out-Null
    }
  }
  Save-InstagramHistory -Items @($history | Select-Object -First 100)
  return [pscustomobject]$entry
}

function Handle-FileHistoryDelete {
  param($Context, [string]$HistoryPath, [string]$FileDir)
  try {
    $payload = Read-BodyJson -Request $Context.Request
  } catch {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Invalid request data." }
    return
  }

  $id = ""
  if ($payload -and $payload.id) {
    $id = ([string]$payload.id).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($id)) {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Missing history id." }
    return
  }

  $history = @(Get-HistoryFromPath -Path $HistoryPath)
  $target = $history | Where-Object { ([string]$_.id) -eq $id } | Select-Object -First 1
  if ($null -eq $target) {
    Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "History item not found." }
    return
  }

  $storedFileName = ""
  if ($target.storedFileName) {
    $storedFileName = [string]$target.storedFileName
  } elseif ($target.fileName) {
    $storedFileName = [string]$target.fileName
  }
  if (-not [string]::IsNullOrWhiteSpace($storedFileName)) {
    $filePath = Join-Path $FileDir (Split-Path -Leaf $storedFileName)
    if (Test-Path -LiteralPath $filePath) {
      Remove-Item -LiteralPath $filePath -Force
    }
  }

  $remaining = @($history | Where-Object { ([string]$_.id) -ne $id })
  Save-HistoryToPath -Path $HistoryPath -Items $remaining
  Send-Json -Context $Context -Status 200 -Object @{ ok = $true; items = @(Get-HistoryFromPath -Path $HistoryPath) }
}

function Test-TikTokVideoUrl {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  try {
    $uri = [Uri]$Value
  } catch {
    return $false
  }
  if ($uri.Scheme -notin @("http", "https")) {
    return $false
  }
  $uriHost = $uri.Host.ToLowerInvariant()
  return ($uriHost -eq "tiktok.com" -or $uriHost.EndsWith(".tiktok.com"))
}

function Test-InstagramVideoUrl {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }
  try {
    $uri = [Uri]$Value
  } catch {
    return $false
  }
  if ($uri.Scheme -notin @("http", "https")) {
    return $false
  }
  $uriHost = $uri.Host.ToLowerInvariant()
  if ($uriHost -ne "instagram.com" -and -not $uriHost.EndsWith(".instagram.com")) {
    return $false
  }
  return ($uri.AbsolutePath -match '^/(reel|reels|p|tv)/')
}

function Get-InstagramUsernameFromInput {
  param([string]$Value)
  $clean = (([string]$Value).Trim() -replace '[、，,]+$', '')
  if ([string]::IsNullOrWhiteSpace($clean)) {
    throw "请输入 Instagram 主页链接"
  }

  if ($clean -match 'instagram\.com/([^/?#\s]+)/?') {
    $username = $Matches[1]
  } elseif ($clean -match '^@?([A-Za-z0-9._]+)$') {
    $username = $Matches[1]
  } else {
    throw "无法识别 Instagram 主页链接"
  }

  if ($username -in @("reel", "reels", "p", "tv", "stories", "explore", "accounts")) {
    throw "请输入 Instagram 用户主页链接，不要输入单条视频链接"
  }
  return $username
}

function Test-InstagramProfileUrl {
  param([string]$Value)
  try {
    [void](Get-InstagramUsernameFromInput -Value $Value)
    return $true
  } catch {
    return $false
  }
}

function Get-InstagramVideoIdFromLink {
  param([string]$Link)
  if ([string]::IsNullOrWhiteSpace($Link)) { return "" }
  $match = [regex]::Match($Link, '/(?:reel|reels|p|tv)/([^/?#]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

function Add-InstagramVideoKeys {
  param([hashtable]$Keys, [string]$Link)
  if ([string]::IsNullOrWhiteSpace($Link)) { return }
  $Keys[$Link] = $true
  $id = Get-InstagramVideoIdFromLink -Link $Link
  if (-not [string]::IsNullOrWhiteSpace($id)) {
    $Keys[$id] = $true
  }
}

function Resolve-DownloadedVideoPath {
  param([array]$Output, [datetime]$StartedAt, [string]$DownloadDir)
  $lines = @($Output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $line = $lines[$i].Trim()
    $candidate = $line
    if (-not [IO.Path]::IsPathRooted($candidate)) {
      $candidate = Join-Path $DownloadDir $candidate
    }
    if ((Test-Path -LiteralPath $candidate) -and ([IO.Path]::GetExtension($candidate).ToLowerInvariant() -eq ".mp4")) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  $recent = Get-ChildItem -LiteralPath $DownloadDir -Filter "*.mp4" -File |
    Where-Object { $_.LastWriteTime -ge $StartedAt.AddSeconds(-2) } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -ne $recent) {
    return $recent.FullName
  }

  return $null
}

function Handle-VideoFileExtract {
  param($Context)
  try {
    $payload = Read-BodyJson -Request $Context.Request
  } catch {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Invalid request data." }
    return
  }

  $videoUrl = ""
  if ($payload -and $payload.videoUrl) {
    $videoUrl = ([string]$payload.videoUrl).Trim()
  }
  if (-not (Test-TikTokVideoUrl -Value $videoUrl)) {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Please enter a valid TikTok video URL." }
    return
  }
  if (-not (Test-YtDlpAvailable)) {
    Send-Json -Context $Context -Status 500 -Object @{ ok = $false; error = "Video download tool was not found." }
    return
  }
  $ytDlpCommand = Get-YtDlpCommand

  $startedAt = Get-Date
  $arguments = @(
    "--no-playlist",
    "--restrict-filenames",
    "--windows-filenames",
    "--force-overwrites",
    "--no-warnings",
    "-f",
    "b[ext=mp4]/best[ext=mp4]/best",
    "--print",
    "after_move:filepath",
    "-P",
    $VideoDownloadDir,
    "-o",
    "%(uploader_id)s_%(id)s.%(ext)s",
    $videoUrl
  )

  try {
    $output = & $ytDlpCommand @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      $message = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
      if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "Video file extraction failed."
      }
      Send-Json -Context $Context -Status 502 -Object @{ ok = $false; error = $message }
      return
    }

    $filePath = Resolve-DownloadedVideoPath -Output $output -StartedAt $startedAt -DownloadDir $VideoDownloadDir
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath)) {
      Send-Json -Context $Context -Status 502 -Object @{ ok = $false; error = "The video was processed, but the generated MP4 file was not found." }
      return
    }

    $file = Get-Item -LiteralPath $filePath
    Add-VideoFileHistoryItem -VideoUrl $videoUrl -File $file | Out-Null
    Send-Json -Context $Context -Status 200 -Object @{
      ok = $true
      fileName = $file.Name
      size = $file.Length
      downloadUrl = "/video-download/$($file.Name)"
    }
  } catch {
    Send-Json -Context $Context -Status 500 -Object @{ ok = $false; error = $_.Exception.Message }
  }
}

function Handle-InstagramExtract {
  param($Context)
  try {
    $payload = Read-BodyJson -Request $Context.Request
  } catch {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Invalid request data." }
    return
  }

  $instagramUrl = ""
  if ($payload -and $payload.instagramUrl) {
    $instagramUrl = ([string]$payload.instagramUrl).Trim()
  }
  if (-not (Test-InstagramVideoUrl -Value $instagramUrl)) {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Please enter a valid Instagram Reel or video URL." }
    return
  }
  if (-not (Test-YtDlpAvailable)) {
    Send-Json -Context $Context -Status 500 -Object @{ ok = $false; error = "Video download tool was not found." }
    return
  }
  $ytDlpCommand = Get-YtDlpCommand

  $startedAt = Get-Date
  $arguments = @(
    "--no-playlist",
    "--restrict-filenames",
    "--windows-filenames",
    "--force-overwrites",
    "--no-warnings",
    "-f",
    "b[ext=mp4]/best[ext=mp4]/best",
    "--print",
    "after_move:filepath",
    "-P",
    $InstagramDownloadDir,
    "-o",
    "instagram_%(id)s.%(ext)s",
    $instagramUrl
  )

  try {
    $output = & $ytDlpCommand @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      $message = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
      if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "Instagram video extraction failed."
      }
      Send-Json -Context $Context -Status 502 -Object @{ ok = $false; error = $message }
      return
    }

    $filePath = Resolve-DownloadedVideoPath -Output $output -StartedAt $startedAt -DownloadDir $InstagramDownloadDir
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath)) {
      Send-Json -Context $Context -Status 502 -Object @{ ok = $false; error = "The video was processed, but the generated MP4 file was not found." }
      return
    }

    $file = Get-Item -LiteralPath $filePath
    Add-InstagramHistoryItem -InstagramUrl $instagramUrl -File $file | Out-Null
    Send-Json -Context $Context -Status 200 -Object @{
      ok = $true
      fileName = $file.Name
      size = $file.Length
      downloadUrl = "/instagram-download/$($file.Name)"
    }
  } catch {
    Send-Json -Context $Context -Status 500 -Object @{ ok = $false; error = $_.Exception.Message }
  }
}

function Escape-Xml {
  param($Value)
  $text = ""
  if ($null -ne $Value) {
    $text = [string]$Value
  }
  return [Security.SecurityElement]::Escape($text)
}

function Add-ZipTextEntry {
  param($Zip, [string]$Name, [string]$Text)
  $entry = $Zip.CreateEntry($Name)
  $stream = $entry.Open()
  $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding $false))
  try {
    $writer.Write($Text)
  } finally {
    $writer.Dispose()
    $stream.Dispose()
  }
}

function New-Xlsx {
  param([array]$Rows, [string]$Path)
  Add-Type -AssemblyName System.IO.Compression | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Force
  }

  $sheetRows = New-Object System.Collections.Generic.List[string]
  $sheetRows.Add('<row r="1"><c r="A1" t="inlineStr"><is><t>Video Link</t></is></c></row>') | Out-Null

  $relationships = New-Object System.Collections.Generic.List[string]
  $rowNumber = 2
  $relNumber = 1
  foreach ($row in $Rows) {
    $link = [string]$row.link
    if ([string]::IsNullOrWhiteSpace($link)) { continue }
    $cell = "A$rowNumber"
    $safeLink = Escape-Xml $link
    $sheetRows.Add("<row r=`"$rowNumber`"><c r=`"$cell`" s=`"1`" t=`"inlineStr`"><is><t>$safeLink</t></is></c></row>") | Out-Null
    $relationships.Add("<Relationship Id=`"rId$relNumber`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink`" Target=`"$safeLink`" TargetMode=`"External`"/>") | Out-Null
    $rowNumber++
    $relNumber++
  }

  $hyperlinks = New-Object System.Collections.Generic.List[string]
  for ($i = 2; $i -lt $rowNumber; $i++) {
    $rid = $i - 1
    $hyperlinks.Add("<hyperlink ref=`"A$i`" r:id=`"rId$rid`"/>") | Out-Null
  }

  $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
    '</Types>'

  $rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
    '</Relationships>'

  $workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
    '<sheets><sheet name="Video Links" sheetId="1" r:id="rId1"/></sheets>' +
    '</workbook>'

  $workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
    '</Relationships>'

  $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
    '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><sz val="11"/><color theme="10"/><name val="Calibri"/><u/></font></fonts>' +
    '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>' +
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
    '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>' +
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>' +
    '</styleSheet>'

  $sheetXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
    '<sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/>' +
    '<cols><col min="1" max="1" width="95" customWidth="1"/></cols>' +
    '<sheetData>' + ($sheetRows -join '') + '</sheetData>' +
    '<hyperlinks>' + ($hyperlinks -join '') + '</hyperlinks>' +
    '<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>' +
    '</worksheet>'

  $sheetRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    ($relationships -join '') +
    '</Relationships>'

  $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
  try {
    Add-ZipTextEntry -Zip $zip -Name "[Content_Types].xml" -Text $contentTypes
    Add-ZipTextEntry -Zip $zip -Name "_rels/.rels" -Text $rootRels
    Add-ZipTextEntry -Zip $zip -Name "xl/workbook.xml" -Text $workbook
    Add-ZipTextEntry -Zip $zip -Name "xl/_rels/workbook.xml.rels" -Text $workbookRels
    Add-ZipTextEntry -Zip $zip -Name "xl/styles.xml" -Text $styles
    Add-ZipTextEntry -Zip $zip -Name "xl/worksheets/sheet1.xml" -Text $sheetXml
    Add-ZipTextEntry -Zip $zip -Name "xl/worksheets/_rels/sheet1.xml.rels" -Text $sheetRels
  } finally {
    $zip.Dispose()
  }
}

function Clean-XlsxText {
  param([object]$Value)
  if ($null -eq $Value) {
    return ""
  }

  $text = [string]$Value
  $builder = New-Object Text.StringBuilder
  foreach ($ch in $text.ToCharArray()) {
    $code = [int][char]$ch
    if ($code -eq 9 -or $code -eq 10 -or $code -eq 13 -or $code -ge 32) {
      [void]$builder.Append($ch)
    }
  }
  return [Security.SecurityElement]::Escape($builder.ToString())
}

function Get-XlsxColumnName {
  param([int]$Number)
  $name = ""
  while ($Number -gt 0) {
    $Number--
    $name = [char](65 + ($Number % 26)) + $name
    $Number = [Math]::Floor($Number / 26)
  }
  return $name
}

function Get-RowValue {
  param($Row, [string]$Key)
  if ($Row -is [Collections.IDictionary]) {
    return $Row[$Key]
  }
  return $Row.PSObject.Properties[$Key].Value
}

function New-ProfileCellXml {
  param([int]$RowNumber, [int]$ColumnNumber, [object]$Value, [bool]$IsNumber, [bool]$IsHeader)
  $ref = "$(Get-XlsxColumnName $ColumnNumber)$RowNumber"
  $style = if ($IsHeader) { ' s="1"' } else { "" }
  if ($IsNumber) {
    if ($null -eq $Value -or $Value -eq "") {
      return "<c r=`"$ref`"$style/>"
    }
    return "<c r=`"$ref`"$style><v>$Value</v></c>"
  }
  $text = Clean-XlsxText $Value
  return "<c r=`"$ref`" t=`"inlineStr`"$style><is><t xml:space=`"preserve`">$text</t></is></c>"
}

function New-ProfileSheetXml {
  param([array]$Headers, [array]$Rows)

  $widths = @{
    1 = 8
    2 = 24
    3 = 24
    4 = 48
    5 = 24
    6 = 22
    7 = 64
    8 = 90
    9 = 12
    10 = 12
    11 = 12
    12 = 22
  }
  $rowCount = $Rows.Count + 1
  $lastCol = Get-XlsxColumnName $Headers.Count
  $sheet = New-Object Text.StringBuilder

  [void]$sheet.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
  [void]$sheet.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
  [void]$sheet.Append("<dimension ref=`"A1:$lastCol$rowCount`"/>")
  [void]$sheet.Append('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>')
  [void]$sheet.Append('<cols>')
  for ($i = 1; $i -le $Headers.Count; $i++) {
    $width = if ($widths.ContainsKey($i)) { $widths[$i] } else { 14 }
    [void]$sheet.Append("<col min=`"$i`" max=`"$i`" width=`"$width`" customWidth=`"1`"/>")
  }
  [void]$sheet.Append('</cols><sheetData>')
  [void]$sheet.Append('<row r="1">')
  for ($i = 0; $i -lt $Headers.Count; $i++) {
    [void]$sheet.Append((New-ProfileCellXml 1 ($i + 1) $Headers[$i] $false $true))
  }
  [void]$sheet.Append('</row>')

  $rowNumber = 2
  foreach ($row in $Rows) {
    [void]$sheet.Append("<row r=`"$rowNumber`">")
    for ($i = 0; $i -lt $Headers.Count; $i++) {
      $header = $Headers[$i]
      $isNumber = $header -in @("序号", "浏览量", "点赞量", "评论数")
      [void]$sheet.Append((New-ProfileCellXml $rowNumber ($i + 1) (Get-RowValue $row $header) $isNumber $false))
    }
    [void]$sheet.Append('</row>')
    $rowNumber++
  }

  [void]$sheet.Append('</sheetData>')
  [void]$sheet.Append("<autoFilter ref=`"A1:$lastCol$rowCount`"/>")
  [void]$sheet.Append('</worksheet>')
  return $sheet.ToString()
}

function Add-XlsxZipEntry {
  param([IO.Compression.ZipArchive]$Zip, [string]$Name, [string]$Content, [Text.Encoding]$Encoding)
  $entry = $Zip.CreateEntry($Name)
  $stream = $entry.Open()
  $writer = New-Object IO.StreamWriter($stream, $Encoding)
  try {
    $writer.Write($Content)
  } finally {
    $writer.Dispose()
    $stream.Dispose()
  }
}

function Get-ProfileChartRows {
  param([array]$Rows)
  return @(
    $Rows | Sort-Object {
      $value = [string](Get-RowValue $_ "发布时间(北京时间)")
      try {
        [DateTime]::ParseExact($value, "yyyy-MM-dd HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
      } catch {
        [DateTime]::MinValue
      }
    }
  )
}

function New-ProfileChartSheetXml {
  param([array]$ChartRows)

  $headers = @("视频序号", "浏览量", "点赞量", "评论数")
  $startRow = 26
  $endRow = $startRow + $ChartRows.Count
  $sheet = New-Object Text.StringBuilder

  [void]$sheet.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
  [void]$sheet.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
  [void]$sheet.Append("<dimension ref=`"A1:D$endRow`"/>")
  [void]$sheet.Append('<sheetViews><sheetView workbookViewId="0"/></sheetViews>')
  [void]$sheet.Append('<cols><col min="1" max="1" width="12" customWidth="1"/><col min="2" max="4" width="14" customWidth="1"/></cols>')
  [void]$sheet.Append('<sheetData>')
  [void]$sheet.Append("<row r=`"$startRow`">")
  for ($i = 0; $i -lt $headers.Count; $i++) {
    [void]$sheet.Append((New-ProfileCellXml $startRow ($i + 1) $headers[$i] $false $true))
  }
  [void]$sheet.Append('</row>')

  for ($i = 0; $i -lt $ChartRows.Count; $i++) {
    $rowNumber = $startRow + $i + 1
    $row = $ChartRows[$i]
    [void]$sheet.Append("<row r=`"$rowNumber`">")
    [void]$sheet.Append((New-ProfileCellXml $rowNumber 1 ($i + 1) $true $false))
    [void]$sheet.Append((New-ProfileCellXml $rowNumber 2 ([int64](Get-RowValue $row "浏览量")) $true $false))
    [void]$sheet.Append((New-ProfileCellXml $rowNumber 3 ([int64](Get-RowValue $row "点赞量")) $true $false))
    [void]$sheet.Append((New-ProfileCellXml $rowNumber 4 ([int64](Get-RowValue $row "评论数")) $true $false))
    [void]$sheet.Append('</row>')
  }

  [void]$sheet.Append('</sheetData>')
  [void]$sheet.Append('<drawing r:id="rId1"/>')
  [void]$sheet.Append('</worksheet>')
  return $sheet.ToString()
}

function New-ProfileDrawingXml {
  param([string]$Platform)
  $name = Clean-XlsxText "$Platform 折线统计图"
  return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <xdr:twoCellAnchor>
    <xdr:from><xdr:col>0</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
    <xdr:to><xdr:col>12</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>23</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>
    <xdr:graphicFrame macro="">
      <xdr:nvGraphicFramePr><xdr:cNvPr id="2" name="$name"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>
      <xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm>
      <a:graphic>
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">
          <c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="rId1"/>
        </a:graphicData>
      </a:graphic>
    </xdr:graphicFrame>
    <xdr:clientData/>
  </xdr:twoCellAnchor>
</xdr:wsDr>
"@
}

function New-ProfileNumCacheXml {
  param([array]$Values)
  $cache = New-Object Text.StringBuilder
  [void]$cache.Append(('<c:numCache><c:formatCode>General</c:formatCode><c:ptCount val="{0}"/>' -f $Values.Count))
  for ($i = 0; $i -lt $Values.Count; $i++) {
    [void]$cache.Append(('<c:pt idx="{0}"><c:v>{1}</c:v></c:pt>' -f $i, $Values[$i]))
  }
  [void]$cache.Append('</c:numCache>')
  return $cache.ToString()
}

function New-ProfileSeriesXml {
  param([int]$Index, [string]$Name, [string]$Color, [string]$ValueColumn, [array]$Categories, [array]$Values, [int]$StartRow, [int]$EndRow)

  $titleRef = "'折线图'!`$$ValueColumn`$$StartRow"
  $catRef = "'折线图'!`$A`$$(($StartRow + 1)):`$A`$$EndRow"
  $valRef = "'折线图'!`$$ValueColumn`$$(($StartRow + 1)):`$$ValueColumn`$$EndRow"
  $catCache = New-ProfileNumCacheXml $Categories
  $valCache = New-ProfileNumCacheXml $Values
  $safeName = Clean-XlsxText $Name

  return @"
<c:ser>
  <c:idx val="$Index"/>
  <c:order val="$Index"/>
  <c:tx><c:strRef><c:f>$titleRef</c:f><c:strCache><c:ptCount val="1"/><c:pt idx="0"><c:v>$safeName</c:v></c:pt></c:strCache></c:strRef></c:tx>
  <c:spPr><a:ln w="28575"><a:solidFill><a:srgbClr val="$Color"/></a:solidFill></a:ln></c:spPr>
  <c:marker><c:symbol val="circle"/><c:size val="5"/><c:spPr><a:solidFill><a:srgbClr val="$Color"/></a:solidFill><a:ln><a:solidFill><a:srgbClr val="$Color"/></a:solidFill></a:ln></c:spPr></c:marker>
  <c:dLbls><c:showLegendKey val="0"/><c:showVal val="1"/><c:showCatName val="0"/><c:showSerName val="0"/><c:showPercent val="0"/><c:showBubbleSize val="0"/></c:dLbls>
  <c:cat><c:numRef><c:f>$catRef</c:f>$catCache</c:numRef></c:cat>
  <c:val><c:numRef><c:f>$valRef</c:f>$valCache</c:numRef></c:val>
  <c:smooth val="0"/>
</c:ser>
"@
}

function New-ProfileChartXml {
  param([array]$ChartRows, [string]$Title, [string]$Platform)

  $startRow = 26
  $endRow = $startRow + $ChartRows.Count
  $categories = @()
  $views = @()
  $likes = @()
  $comments = @()
  for ($i = 0; $i -lt $ChartRows.Count; $i++) {
    $row = $ChartRows[$i]
    $categories += ($i + 1)
    $views += [int64](Get-RowValue $row "浏览量")
    $likes += [int64](Get-RowValue $row "点赞量")
    $comments += [int64](Get-RowValue $row "评论数")
  }

  $safeTitle = Clean-XlsxText "$Title $Platform 视频数据折线统计图"
  $viewsSeries = New-ProfileSeriesXml 0 "浏览量" "DC2626" "B" $categories $views $startRow $endRow
  $likesSeries = New-ProfileSeriesXml 1 "点赞量" "16A34A" "C" $categories $likes $startRow $endRow
  $commentsSeries = New-ProfileSeriesXml 2 "评论量" "2563EB" "D" $categories $comments $startRow $endRow

  return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <c:date1904 val="0"/><c:lang val="zh-CN"/><c:roundedCorners val="0"/>
  <c:chart>
    <c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="1400"/><a:t>$safeTitle</a:t></a:r></a:p></c:rich></c:tx><c:layout/><c:overlay val="0"/></c:title>
    <c:plotArea>
      <c:layout/>
      <c:lineChart><c:grouping val="standard"/><c:varyColors val="0"/>$viewsSeries$likesSeries$commentsSeries<c:axId val="1001"/><c:axId val="1002"/></c:lineChart>
      <c:catAx><c:axId val="1001"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/><c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/><c:crossAx val="1002"/><c:crosses val="autoZero"/><c:auto val="1"/><c:lblAlgn val="ctr"/><c:lblOffset val="100"/></c:catAx>
      <c:valAx><c:axId val="1002"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:majorGridlines/><c:numFmt formatCode="General" sourceLinked="1"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/><c:crossAx val="1001"/><c:crosses val="autoZero"/><c:crossBetween val="between"/></c:valAx>
    </c:plotArea>
    <c:legend><c:legendPos val="b"/><c:layout/><c:overlay val="0"/></c:legend>
    <c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/><c:showDLblsOverMax val="0"/>
  </c:chart>
</c:chartSpace>
"@
}

function New-ProfileWorkbookBytes {
  param([array]$Rows, [string]$SheetName, [bool]$IncludeChart = $false, [string]$Platform = "Instagram")

  Add-Type -AssemblyName System.IO.Compression | Out-Null

  $headers = @("序号", "账号", "账号昵称", "账号主页", "视频ID", "发布时间(北京时间)", "视频链接", "文案", "浏览量", "点赞量", "评论数", "取数时间(北京时间)")
  $sheetXml = New-ProfileSheetXml $headers $Rows
  $chartRows = Get-ProfileChartRows $Rows
  $chartSheetXml = if ($IncludeChart) { New-ProfileChartSheetXml $chartRows } else { $null }
  $drawingXml = if ($IncludeChart) { New-ProfileDrawingXml $Platform } else { $null }
  $chartXml = if ($IncludeChart) { New-ProfileChartXml $chartRows $SheetName $Platform } else { $null }
  $safeSheetName = Clean-XlsxText (($SheetName -replace '[:\\/?*\[\]]', "").Trim())
  if ([string]::IsNullOrWhiteSpace($safeSheetName)) { $safeSheetName = "视频数据" }
  if ($safeSheetName.Length -gt 31) { $safeSheetName = $safeSheetName.Substring(0, 31) }

  if ($IncludeChart) {
    $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/><Override PartName="/xl/charts/chart1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
    $workbook = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><sheets><sheet name=`"$safeSheetName`" sheetId=`"1`" r:id=`"rId1`"/><sheet name=`"折线图`" sheetId=`"2`" r:id=`"rId2`"/></sheets></workbook>"
    $workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
  } else {
    $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
    $workbook = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><sheets><sheet name=`"$safeSheetName`" sheetId=`"1`" r:id=`"rId1`"/></sheets></workbook>"
    $workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
  }

  $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>'
  $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFEFEFEF"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
  $now = [DateTimeOffset]::Now.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $coreTitle = Clean-XlsxText "$Platform 视频数据"
  $core = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><cp:coreProperties xmlns:cp=`"http://schemas.openxmlformats.org/package/2006/metadata/core-properties`" xmlns:dc=`"http://purl.org/dc/elements/1.1/`" xmlns:dcterms=`"http://purl.org/dc/terms/`" xmlns:dcmitype=`"http://purl.org/dc/dcmitype/`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`"><dc:title>$coreTitle</dc:title><dc:creator>Codex</dc:creator><cp:lastModifiedBy>Codex</cp:lastModifiedBy><dcterms:created xsi:type=`"dcterms:W3CDTF`">$now</dcterms:created><dcterms:modified xsi:type=`"dcterms:W3CDTF`">$now</dcterms:modified></cp:coreProperties>"
  $app = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Codex</Application></Properties>'

  $encoding = New-Object Text.UTF8Encoding $false
  $memoryStream = New-Object IO.MemoryStream
  $zip = New-Object IO.Compression.ZipArchive($memoryStream, [IO.Compression.ZipArchiveMode]::Create, $true)
  try {
    Add-XlsxZipEntry $zip "[Content_Types].xml" $contentTypes $encoding
    Add-XlsxZipEntry $zip "_rels/.rels" $rels $encoding
    Add-XlsxZipEntry $zip "xl/workbook.xml" $workbook $encoding
    Add-XlsxZipEntry $zip "xl/_rels/workbook.xml.rels" $workbookRels $encoding
    Add-XlsxZipEntry $zip "xl/worksheets/sheet1.xml" $sheetXml $encoding
    if ($IncludeChart) {
      Add-XlsxZipEntry $zip "xl/worksheets/sheet2.xml" $chartSheetXml $encoding
      Add-XlsxZipEntry $zip "xl/worksheets/_rels/sheet2.xml.rels" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>' $encoding
      Add-XlsxZipEntry $zip "xl/drawings/drawing1.xml" $drawingXml $encoding
      Add-XlsxZipEntry $zip "xl/drawings/_rels/drawing1.xml.rels" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart1.xml"/></Relationships>' $encoding
      Add-XlsxZipEntry $zip "xl/charts/chart1.xml" $chartXml $encoding
    }
    Add-XlsxZipEntry $zip "xl/styles.xml" $styles $encoding
    Add-XlsxZipEntry $zip "docProps/core.xml" $core $encoding
    Add-XlsxZipEntry $zip "docProps/app.xml" $app $encoding
  } finally {
    $zip.Dispose()
  }

  $bytes = $memoryStream.ToArray()
  $memoryStream.Dispose()
  return $bytes
}

function Add-Unique {
  param([System.Collections.Generic.List[string]]$List, [string]$Value)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $trimmed = $Value.Trim()
    if (-not $List.Contains($trimmed)) {
      $List.Add($trimmed) | Out-Null
    }
  }
}

function Get-ImageSummary {
  param($Images)
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($image in @($Images)) {
    if ($null -eq $image) { continue }
    $colors = @($image.colors) -join "/"
    Add-Unique $parts ("{0} {1}x{2} {3}" -f $image.name, $image.width, $image.height, $colors)
  }
  return ($parts -join "; ")
}

function ConvertTo-Hex {
  param([byte[]]$Bytes)
  return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-Sha256Text {
  param([string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ConvertTo-Hex ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))
  } finally {
    $sha.Dispose()
  }
}

function Get-InputSignature {
  param([string]$Text, $Images)
  $normalizedText = (($Text -replace '\s+', ' ').Trim()).ToLowerInvariant()
  $imageKeys = New-Object System.Collections.Generic.List[string]
  foreach ($image in @($Images)) {
    if ($null -eq $image) { continue }
    if ($image.hash) {
      Add-Unique $imageKeys ([string]$image.hash)
      continue
    }
    $colors = @($image.colors) -join "/"
    Add-Unique $imageKeys ("{0}:{1}:{2}:{3}:{4}" -f $image.name, $image.size, $image.width, $image.height, $colors)
  }
  $joinedImages = (@($imageKeys | Sort-Object) -join "|")
  return Get-Sha256Text ($normalizedText + "::" + $joinedImages)
}

function Add-VideoKeys {
  param([hashtable]$Keys, [string]$Link)
  if ([string]::IsNullOrWhiteSpace($Link)) { return }
  $Keys[$Link] = $true
  $match = [regex]::Match($Link, '/video/(\d+)')
  if ($match.Success) {
    $Keys[$match.Groups[1].Value] = $true
  }
}

function Get-HistoryItemLinks {
  param($Item)
  $links = New-Object System.Collections.Generic.List[string]
  foreach ($link in @($Item.links)) {
    if (-not [string]::IsNullOrWhiteSpace($link)) {
      Add-Unique $links ([string]$link)
    }
  }
  if ($links.Count -gt 0) {
    return @($links)
  }

  if (-not $Item.fileName) {
    return @()
  }
  $filePath = Join-Path $ExportDir ([string]$Item.fileName)
  if (-not (Test-Path -LiteralPath $filePath)) {
    return @()
  }

  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($filePath)
    try {
      $entry = $zip.Entries | Where-Object { $_.FullName -eq "xl/worksheets/_rels/sheet1.xml.rels" } | Select-Object -First 1
      if ($null -eq $entry) { return @() }
      $reader = New-Object IO.StreamReader($entry.Open())
      try {
        $xml = $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }
      foreach ($match in [regex]::Matches($xml, 'Target="([^"]+)"')) {
        $link = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
        if ($link -match '^https://www\.tiktok\.com/') {
          Add-Unique $links $link
        }
      }
    } finally {
      $zip.Dispose()
    }
  } catch {
    return @()
  }
  return @($links)
}

function Get-ExcludedVideoKeys {
  param([string]$InputSignature, [string]$Text, [string]$ImageSummary)
  $keys = @{}
  foreach ($item in @(Get-History)) {
    if ($null -eq $item) { continue }
    $sameSignature = $false
    if ($item.inputSignature -and ([string]$item.inputSignature) -eq $InputSignature) {
      $sameSignature = $true
    } elseif ((-not $item.inputSignature) -and ([string]$item.text) -eq $Text -and ([string]$item.imageSummary) -eq $ImageSummary) {
      $sameSignature = $true
    }
    if (-not $sameSignature) { continue }
    foreach ($link in @(Get-HistoryItemLinks -Item $item)) {
      Add-VideoKeys -Keys $keys -Link $link
    }
  }
  return $keys
}

function Get-InstagramHistoryItemLinks {
  param($Item)
  $links = New-Object System.Collections.Generic.List[string]
  foreach ($link in @($Item.links)) {
    if (-not [string]::IsNullOrWhiteSpace($link)) {
      Add-Unique $links ([string]$link)
    }
  }
  return @($links)
}

function Get-InstagramExcludedVideoKeys {
  param([string]$InputSignature, [string]$Text, [string]$ImageSummary)
  $keys = @{}
  foreach ($item in @(Get-InstagramLinkHistory)) {
    if ($null -eq $item) { continue }
    $sameSignature = $false
    if ($item.inputSignature -and ([string]$item.inputSignature) -eq $InputSignature) {
      $sameSignature = $true
    } elseif ((-not $item.inputSignature) -and ([string]$item.text) -eq $Text -and ([string]$item.imageSummary) -eq $ImageSummary) {
      $sameSignature = $true
    }
    if (-not $sameSignature) { continue }
    foreach ($link in @(Get-InstagramHistoryItemLinks -Item $item)) {
      Add-InstagramVideoKeys -Keys $keys -Link $link
    }
  }
  return $keys
}

function Test-HasCodePoint {
  param([string]$Text, [int[]]$Codes)
  foreach ($code in $Codes) {
    if ($Text.IndexOf([char]$code) -ge 0) {
      return $true
    }
  }
  return $false
}

function Test-HasCodeSequence {
  param([string]$Text, [int[]]$Codes)
  $chars = New-Object System.Collections.Generic.List[char]
  foreach ($code in $Codes) {
    $chars.Add([char]$code) | Out-Null
  }
  $sequence = -join $chars
  return $Text.Contains($sequence)
}

function Get-SearchQueries {
  param([string]$Text, $Images)
  $queries = New-Object System.Collections.Generic.List[string]
  $tokens = New-Object System.Collections.Generic.List[string]
  $lower = $Text.ToLowerInvariant()
  $imageColors = @($Images | ForEach-Object { $_.colors } | Where-Object { $_ }) | Select-Object -Unique

  foreach ($color in $imageColors) {
    if ($color -in @("black", "dark gray", "gray", "white", "red", "orange", "yellow", "green", "blue", "purple", "brown")) {
      Add-Unique $tokens $color
    }
  }

  if (($lower -match "black") -or (Test-HasCodePoint $Text @(0x9ED1))) { Add-Unique $tokens "black" }
  if (($lower -match "white") -or (Test-HasCodePoint $Text @(0x767D))) { Add-Unique $tokens "white" }
  if (($lower -match "gray|grey") -or (Test-HasCodePoint $Text @(0x7070))) { Add-Unique $tokens "gray" }
  if (($lower -match "blue") -or (Test-HasCodePoint $Text @(0x84DD))) { Add-Unique $tokens "blue" }
  if (($lower -match "red") -or (Test-HasCodePoint $Text @(0x7EA2))) { Add-Unique $tokens "red" }
  if (($lower -match "green") -or (Test-HasCodePoint $Text @(0x7EFF))) { Add-Unique $tokens "green" }
  if (($lower -match "brown") -or (Test-HasCodePoint $Text @(0x68D5))) { Add-Unique $tokens "brown" }
  if (($lower -match "fold") -or (Test-HasCodeSequence $Text @(0x6298,0x53E0)) -or (Test-HasCodeSequence $Text @(0x6298,0x8FED))) { Add-Unique $tokens "folding"; Add-Unique $tokens "foldable" }
  if (($lower -match "camp") -or (Test-HasCodeSequence $Text @(0x9732,0x8425)) -or (Test-HasCodeSequence $Text @(0x91CE,0x8425))) { Add-Unique $tokens "camping"; Add-Unique $tokens "camp chair" }
  if (($lower -match "outdoor") -or (Test-HasCodeSequence $Text @(0x6237,0x5916)) -or (Test-HasCodeSequence $Text @(0x5BA4,0x5916))) { Add-Unique $tokens "outdoor" }
  if (($lower -match "armrest|arm chair|armchair") -or (Test-HasCodeSequence $Text @(0x6276,0x624B))) { Add-Unique $tokens "arm chair"; Add-Unique $tokens "armrest" }
  if (($lower -match "chair") -or (Test-HasCodePoint $Text @(0x6905))) { Add-Unique $tokens "chair" }
  if (($lower -match "cup|drink") -or (Test-HasCodePoint $Text @(0x676F)) -or (Test-HasCodeSequence $Text @(0x6C34,0x676F))) { Add-Unique $tokens "cup holder"; Add-Unique $tokens "drink holder" }
  if (($lower -match "mesh") -or (Test-HasCodePoint $Text @(0x7F51)) -or (Test-HasCodeSequence $Text @(0x7F51,0x515C)) -or (Test-HasCodeSequence $Text @(0x7F51,0x888B))) { Add-Unique $tokens "mesh" }
  if (($lower -match "steel|metal") -or (Test-HasCodeSequence $Text @(0x91D1,0x5C5E)) -or (Test-HasCodePoint $Text @(0x94A2,0x94C1)) -or (Test-HasCodeSequence $Text @(0x652F,0x67B6))) { Add-Unique $tokens "steel frame" }
  if (($lower -match "carry|bag|pocket") -or (Test-HasCodeSequence $Text @(0x6536,0x7EB3)) -or (Test-HasCodeSequence $Text @(0x50A8,0x7269)) -or (Test-HasCodeSequence $Text @(0x4FA7,0x888B))) { Add-Unique $tokens "carry bag"; Add-Unique $tokens "side pocket" }

  Add-Unique $queries $Text
  $joined = ($tokens | Select-Object -First 10) -join " "
  Add-Unique $queries $joined

  $looksLikeChair = (($lower -match "chair|camp") -or (Test-HasCodePoint $Text @(0x6905)) -or (Test-HasCodeSequence $Text @(0x9732,0x8425)) -or (Test-HasCodeSequence $Text @(0x6276,0x624B)))
  $color = ""
  if ($tokens.Contains("black")) { $color = "black " }
  elseif ($tokens.Contains("gray")) { $color = "gray " }
  elseif ($tokens.Contains("blue")) { $color = "blue " }

  if ($looksLikeChair) {
    Add-Unique $queries ("{0}folding camping chair cup holder" -f $color)
    Add-Unique $queries ("{0}basic quad folding camp chair cup holder" -f $color)
    Add-Unique $queries ("{0}foldable arm chair camping cup holder" -f $color)
    Add-Unique $queries ("{0}camp chair mesh cup holder steel frame" -f $color)
  }

  return @($queries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 8)
}

function ConvertTo-InstagramTag {
  param([string]$Value)
  $tag = ([string]$Value).ToLowerInvariant()
  $tag = $tag -replace '[^a-z0-9]+', ''
  if ($tag.Length -gt 40) {
    $tag = $tag.Substring(0, 40)
  }
  return $tag
}

function Get-InstagramTagQueries {
  param([string]$Text, $Images)
  $tags = New-Object System.Collections.Generic.List[string]
  foreach ($query in @(Get-SearchQueries -Text $Text -Images $Images)) {
    $tag = ConvertTo-InstagramTag -Value $query
    Add-Unique $tags $tag
    foreach ($word in ($query -split '\s+')) {
      $wordTag = ConvertTo-InstagramTag -Value $word
      if ($wordTag.Length -ge 3) {
        Add-Unique $tags $wordTag
      }
    }
  }

  $lower = $Text.ToLowerInvariant()
  if (($lower -match "chair|camp") -or (Test-HasCodePoint $Text @(0x6905)) -or (Test-HasCodeSequence $Text @(0x9732,0x8425))) {
    foreach ($tag in @("campingchair", "foldingchair", "outdoorchair", "campchair", "portablechair")) {
      Add-Unique $tags $tag
    }
  }

  return @($tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 12)
}

function Get-MatchScore {
  param([string]$Title, [string]$Query, [bool]$ChairMode)
  $text = ($Title + " " + $Query).ToLowerInvariant()
  $score = 0
  foreach ($word in @("black", "basic", "quad", "folding", "foldable", "camp chair", "camping chair", "cup holder", "drink holder", "mesh", "steel frame", "carry bag", "armrest", "outdoor")) {
    if ($text.Contains($word)) { $score += 2 }
  }
  if ($text -match "campingchair|foldingchair|foldablechair|portablechair") { $score += 2 }
  if ($ChairMode) {
    foreach ($bad in @("swing", "swinging", "hammock", "rocker", "rocking", "zero gravity", "recliner", "reclining", "double", "umbrella", "canopy", "sunshade", "wheelchair", "adirondack", "stool", "sofa", "loveseat", "chaise")) {
      if ($text.Contains($bad)) { $score -= 5 }
    }
  }
  return $score
}

function Search-TikTokVideos {
  param([array]$Queries, [string]$InputText, [string]$ImageSummary, [hashtable]$ExcludeKeys, [int]$TargetCount = 15)
  $seen = @{}
  $items = New-Object System.Collections.Generic.List[object]
  $chairMode = (($InputText.ToLowerInvariant() -match "chair|camp") -or (Test-HasCodePoint $InputText @(0x6905)) -or (Test-HasCodeSequence $InputText @(0x9732,0x8425)) -or (Test-HasCodeSequence $InputText @(0x6276,0x624B)))

  foreach ($query in $Queries) {
    foreach ($cursor in @(0, 30, 60, 90)) {
      $encoded = [Uri]::EscapeDataString($query)
      $url = "https://www.tikwm.com/api/feed/search?keywords=$encoded&count=30&cursor=$cursor"
      try {
        $response = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = "Mozilla/5.0"; "Accept" = "application/json" } -UseBasicParsing -TimeoutSec 35
        $payload = $response.Content | ConvertFrom-Json
        foreach ($video in @($payload.data.videos)) {
          if ($null -eq $video.video_id) { continue }
          $id = [string]$video.video_id
          if ($seen.ContainsKey($id)) { continue }
          if ($ExcludeKeys -and $ExcludeKeys.ContainsKey($id)) { continue }
          $author = ""
          if ($video.author -and $video.author.unique_id) { $author = [string]$video.author.unique_id }
          if ([string]::IsNullOrWhiteSpace($author)) { continue }
          $link = "https://www.tiktok.com/@$author/video/$id"
          if ($ExcludeKeys -and $ExcludeKeys.ContainsKey($link)) { continue }
          $title = [string]$video.title
          $score = Get-MatchScore -Title $title -Query $query -ChairMode $chairMode
          if ($chairMode -and $score -lt 4) { continue }
          $seen[$id] = $true
          $items.Add([pscustomobject]@{
            id = $id
            author = $author
            title = $title
            link = $link
            query = $query
            score = $score
            duration = $video.duration
            playCount = $video.play_count
            likeCount = $video.digg_count
            commentCount = $video.comment_count
            extractedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            inputText = $InputText
            imageSummary = $ImageSummary
          }) | Out-Null
        }
      } catch {
        continue
      }
      if ($items.Count -ge ($TargetCount * 2)) { break }
    }
  }

  return @($items | Sort-Object score -Descending | Select-Object -First $TargetCount)
}

function Get-YtDlpJsonObjects {
  param([array]$Arguments)
  if (-not (Test-YtDlpAvailable)) {
    throw "Video download tool was not found."
  }

  $ytDlpCommand = Get-YtDlpCommand
  $output = & $ytDlpCommand @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $message = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($message)) {
      $message = "yt-dlp extraction failed."
    }
    throw $message
  }

  $objects = New-Object System.Collections.Generic.List[object]
  foreach ($line in @($output | ForEach-Object { [string]$_ })) {
    $text = $line.Trim()
    if (-not $text.StartsWith("{")) { continue }
    try {
      $objects.Add(($text | ConvertFrom-Json)) | Out-Null
    } catch {
      continue
    }
  }
  return @($objects)
}

function Get-InstagramLinkFromEntry {
  param($Entry)
  foreach ($name in @("webpage_url", "original_url", "url")) {
    $value = [string]$Entry.PSObject.Properties[$name].Value
    if ($value -match '^https?://(www\.)?instagram\.com/(reel|reels|p|tv)/') {
      return $value
    }
  }

  $id = [string]$Entry.id
  if ([string]::IsNullOrWhiteSpace($id)) {
    $id = [string]$Entry.display_id
  }
  if (-not [string]::IsNullOrWhiteSpace($id)) {
    return "https://www.instagram.com/reel/$id/"
  }
  return ""
}

function Search-InstagramVideos {
  param([array]$Tags, [string]$InputText, [string]$ImageSummary, [hashtable]$ExcludeKeys, [int]$TargetCount = 15)
  $seen = @{}
  $items = New-Object System.Collections.Generic.List[object]

  foreach ($tag in $Tags) {
    $tagText = ConvertTo-InstagramTag -Value $tag
    if ([string]::IsNullOrWhiteSpace($tagText)) { continue }
    $tagUrl = "https://www.instagram.com/explore/tags/$tagText/"
    try {
      $entries = Get-YtDlpJsonObjects -Arguments @(
        "--ignore-errors",
        "--no-warnings",
        "--flat-playlist",
        "--dump-json",
        "--playlist-end",
        "40",
        $tagUrl
      )
    } catch {
      $entries = @()
    }

    if (-not @($entries).Count) {
      try {
        $entries = @(Get-InstagramHashtagEntriesFromWebInfo -Tag $tagText -Limit 40)
      } catch {
        $entries = @()
      }
    }

    foreach ($entry in @($entries)) {
      $link = Get-InstagramLinkFromEntry -Entry $entry
      if ([string]::IsNullOrWhiteSpace($link)) { continue }
      $id = Get-InstagramVideoIdFromLink -Link $link
      $key = if ([string]::IsNullOrWhiteSpace($id)) { $link } else { $id }
      if ($seen.ContainsKey($key)) { continue }
      if ($ExcludeKeys -and ($ExcludeKeys.ContainsKey($key) -or $ExcludeKeys.ContainsKey($link))) { continue }

      $seen[$key] = $true
      $title = ""
      if ($entry.title) { $title = [string]$entry.title }
      elseif ($entry.description) { $title = [string]$entry.description }

      $items.Add([pscustomobject]@{
        id = $key
        author = [string]$entry.uploader_id
        title = $title
        link = $link
        query = "#$tagText"
        score = 1
        duration = $entry.duration
        playCount = $entry.view_count
        likeCount = $entry.like_count
        commentCount = $entry.comment_count
        extractedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        inputText = $InputText
        imageSummary = $ImageSummary
      }) | Out-Null
      if ($items.Count -ge $TargetCount) { break }
    }
    if ($items.Count -ge $TargetCount) { break }
  }

  return @($items | Select-Object -First $TargetCount)
}

function ConvertTo-Int64Safe {
  param($Value)
  try {
    if ($null -eq $Value -or $Value -eq "") { return 0 }
    return [int64]$Value
  } catch {
    return 0
  }
}

function ConvertTo-FriendlyInstagramError {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) {
    return "Instagram 数据读取失败。"
  }
  if ($Message -match "429|Too Many Requests") {
    return "Instagram 当前限制了公开访问或触发了频率限制。请稍后重试，或在本机浏览器登录 Instagram 后再试。"
  }
  if ($Message -match "Page not found|404|Not Found") {
    return "Instagram 没有返回可读取的公开页面。请确认主页或视频链接可以在浏览器打开；如果链接能打开，可能需要在本机浏览器登录 Instagram 后重试。"
  }
  if ($Message -match "Unable to extract data|login|cookies|not logged") {
    return "Instagram 数据读取失败。请确认链接为公开内容；如果仍失败，可能需要在本机浏览器登录 Instagram 后重试。"
  }
  return $Message
}

function ConvertTo-FriendlyTikTokError {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) {
    return "TikTok 主页数据读取失败。"
  }
  if ($Message -match "403|Forbidden|已禁止") {
    return "TikTok 数据接口当前拒绝访问。已尝试备用接口仍失败，请稍后重试，或换一个公开视频主页链接。"
  }
  if ($Message -match "connect|连接|Could not connect|无法连接") {
    return "当前网络无法连接 TikTok 数据接口，请检查网络后重试。"
  }
  return $Message
}

function Get-TikTokUsernameFromInput {
  param([string]$InputValue)

  $value = ([string]$InputValue).Trim()
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "请输入 TikTok 主页链接"
  }

  if ($value -match 'tiktok\.com/@([^/?#\s]+)') {
    return $Matches[1]
  }
  if ($value -match '^@?([A-Za-z0-9._-]+)$') {
    return $Matches[1]
  }
  throw "无法识别 TikTok 主页链接"
}

function Invoke-TikwmJsonLocal {
  param([string]$PathAndQuery)

  $errors = New-Object System.Collections.Generic.List[string]
  foreach ($base in @("https://www.tikwm.com", "https://tikwm.com")) {
    $url = "$base$PathAndQuery"
    for ($i = 1; $i -le 3; $i++) {
      try {
        $response = Invoke-WebRequest -Uri $url -Headers @{
          "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
          "Accept" = "application/json,text/plain,*/*"
          "Referer" = "$base/"
        } -UseBasicParsing -TimeoutSec 35
        $json = $response.Content | ConvertFrom-Json
        if ($json.code -eq 0) {
          return $json
        }
        $message = if ($json.msg) { [string]$json.msg } else { "TikWM returned code $($json.code)." }
        $errors.Add("$url : $message") | Out-Null
        if ($message -match "Limit|request|频繁") {
          Start-Sleep -Seconds ([Math]::Min(2 * $i, 8))
          continue
        }
        break
      } catch {
        $errors.Add("$url : $($_.Exception.Message)") | Out-Null
        if ($i -lt 3) {
          Start-Sleep -Seconds ([Math]::Min(2 * $i, 8))
        }
      }
    }
  }

  throw (($errors | Select-Object -Last 3) -join "`n")
}

function Get-TikTokProfileVideoRowsLocal {
  param([string]$ProfileInput, [int]$RequestedCount)

  if ($RequestedCount -lt 1) {
    throw "提取数量必须大于 0"
  }

  $username = Get-TikTokUsernameFromInput -InputValue $ProfileInput
  $encodedUsername = [Uri]::EscapeDataString($username)
  $info = Invoke-TikwmJsonLocal -PathAndQuery "/api/user/info?unique_id=$encodedUsername"
  if ($null -eq $info -or $info.code -ne 0) {
    $message = if ($info.msg) { [string]$info.msg } else { "无法读取账号信息" }
    throw $message
  }

  $nickname = [string]$info.data.user.nickname
  if ([string]::IsNullOrWhiteSpace($nickname)) { $nickname = $username }
  $profileVideoCount = 0
  try { $profileVideoCount = [int]$info.data.stats.videoCount } catch {}
  $targetCount = if ($profileVideoCount -gt 0) { [Math]::Min($RequestedCount, $profileVideoCount) } else { $RequestedCount }
  $snapshot = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss")
  $all = @()
  $cursor = "0"
  $page = 0

  while ($all.Count -lt $targetCount -and $page -lt 50) {
    $page++
    if ($page -gt 1) { Start-Sleep -Milliseconds 800 }
    $posts = Invoke-TikwmJsonLocal -PathAndQuery "/api/user/posts?unique_id=$encodedUsername&count=30&cursor=$cursor"
    if ($null -eq $posts -or $posts.code -ne 0) {
      $message = if ($posts.msg) { [string]$posts.msg } else { "无法读取视频列表" }
      throw $message
    }

    $all += @($posts.data.videos)
    $cursor = [string]$posts.data.cursor
    $hasMore = [bool]$posts.data.hasMore
    if (-not $hasMore) { break }
  }

  $videos = @($all | Where-Object { $null -ne $_ -and $_.video_id } | Sort-Object video_id -Unique | Sort-Object create_time -Descending | Select-Object -First $targetCount)
  if (-not $videos.Count) {
    throw "没有找到可导出的 TikTok 视频。"
  }

  $rows = New-Object System.Collections.Generic.List[object]
  $index = 1
  foreach ($video in $videos) {
    $created = $snapshot
    try {
      $created = [DateTimeOffset]::FromUnixTimeSeconds([int64]$video.create_time).ToOffset([TimeSpan]::FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss")
    } catch {}
    $rows.Add([ordered]@{
      "序号" = $index
      "账号" = "@" + $username
      "账号昵称" = $nickname
      "账号主页" = "https://www.tiktok.com/@$username"
      "视频ID" = [string]$video.video_id
      "发布时间(北京时间)" = $created
      "视频链接" = "https://www.tiktok.com/@$username/video/$($video.video_id)"
      "文案" = ([string]$video.title).Trim()
      "浏览量" = (ConvertTo-Int64Safe $video.play_count)
      "点赞量" = (ConvertTo-Int64Safe $video.digg_count)
      "评论数" = (ConvertTo-Int64Safe $video.comment_count)
      "取数时间(北京时间)" = $snapshot
    }) | Out-Null
    $index++
  }

  return [pscustomobject]@{
    Username = $username
    Nickname = $nickname
    RequestedCount = $RequestedCount
    ProfileVideoCount = if ($profileVideoCount -gt 0) { $profileVideoCount } else { $videos.Count }
    ExtractedCount = $videos.Count
    Rows = [object[]]$rows.ToArray()
  }
}

function Invoke-InstagramApiJson {
  param([string]$Url, [string]$Referer)
  $headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
    "Accept" = "application/json,text/plain,*/*"
    "X-IG-App-ID" = "936619743392459"
    "Referer" = $Referer
  }
  $response = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 30
  return $response.Content | ConvertFrom-Json
}

function Convert-InstagramMediaToEntry {
  param($Media, [string]$Username)
  if ($null -eq $Media) { return $null }

  $shortcode = ""
  foreach ($name in @("shortcode", "code")) {
    if ($Media.PSObject.Properties[$name].Value) {
      $shortcode = [string]$Media.PSObject.Properties[$name].Value
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($shortcode)) {
    return $null
  }

  $isVideo = $false
  if ($Media.is_video) { $isVideo = [bool]$Media.is_video }
  if ($Media.media_type -and [int]$Media.media_type -eq 2) { $isVideo = $true }

  $caption = ""
  try {
    $caption = [string]$Media.edge_media_to_caption.edges[0].node.text
  } catch {}
  if ([string]::IsNullOrWhiteSpace($caption)) {
    try { $caption = [string]$Media.caption.text } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($caption) -and $Media.title) {
    $caption = [string]$Media.title
  }

  $owner = $Username
  try {
    if ($Media.owner.username) { $owner = [string]$Media.owner.username }
  } catch {}
  try {
    if ($Media.user.username) { $owner = [string]$Media.user.username }
  } catch {}

  $views = 0
  foreach ($name in @("video_view_count", "video_play_count", "view_count", "play_count")) {
    if ($Media.PSObject.Properties[$name].Value) {
      $views = ConvertTo-Int64Safe $Media.PSObject.Properties[$name].Value
      break
    }
  }
  $likes = 0
  try { $likes = ConvertTo-Int64Safe $Media.edge_liked_by.count } catch {}
  if ($likes -eq 0) {
    try { $likes = ConvertTo-Int64Safe $Media.edge_media_preview_like.count } catch {}
  }
  if ($likes -eq 0) {
    try { $likes = ConvertTo-Int64Safe $Media.like_count } catch {}
  }
  $comments = 0
  try { $comments = ConvertTo-Int64Safe $Media.edge_media_to_comment.count } catch {}
  if ($comments -eq 0) {
    try { $comments = ConvertTo-Int64Safe $Media.comment_count } catch {}
  }

  $timestamp = $null
  foreach ($name in @("taken_at_timestamp", "taken_at", "caption_created_at")) {
    if ($Media.PSObject.Properties[$name].Value) {
      $timestamp = $Media.PSObject.Properties[$name].Value
      break
    }
  }

  return [pscustomobject]@{
    id = $shortcode
    display_id = $shortcode
    webpage_url = if ($isVideo) { "https://www.instagram.com/reel/$shortcode/" } else { "https://www.instagram.com/p/$shortcode/" }
    title = $caption
    description = $caption
    uploader_id = $owner
    timestamp = $timestamp
    view_count = $views
    like_count = $likes
    comment_count = $comments
    is_video = $isVideo
  }
}

function Get-InstagramProfileEntriesFromWebInfo {
  param([string]$Username, [int]$RequestedCount)
  $encoded = [Uri]::EscapeDataString($Username)
  $profileUrl = "https://www.instagram.com/$Username/"
  $payload = Invoke-InstagramApiJson -Url "https://www.instagram.com/api/v1/users/web_profile_info/?username=$encoded" -Referer $profileUrl
  $user = $payload.data.user
  if ($null -eq $user) {
    throw "无法读取 Instagram 主页公开数据。"
  }

  $nodes = New-Object System.Collections.Generic.List[object]
  foreach ($edge in @($user.edge_owner_to_timeline_media.edges)) {
    if ($edge.node) { $nodes.Add($edge.node) | Out-Null }
  }
  foreach ($edge in @($user.edge_felix_video_timeline.edges)) {
    if ($edge.node) { $nodes.Add($edge.node) | Out-Null }
  }

  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($node in @($nodes | Select-Object -First $RequestedCount)) {
    $entry = Convert-InstagramMediaToEntry -Media $node -Username $Username
    if ($null -ne $entry) { $entries.Add($entry) | Out-Null }
  }

  return [pscustomobject]@{
    Username = $Username
    Nickname = if ($user.full_name) { [string]$user.full_name } else { $Username }
    ProfileVideoCount = if ($user.edge_owner_to_timeline_media.count) { [int]$user.edge_owner_to_timeline_media.count } else { $entries.Count }
    Entries = [object[]]$entries.ToArray()
  }
}

function Get-InstagramHashtagEntriesFromWebInfo {
  param([string]$Tag, [int]$Limit = 40)
  $encoded = [Uri]::EscapeDataString($Tag)
  $payload = Invoke-InstagramApiJson -Url "https://www.instagram.com/api/v1/tags/web_info/?tag_name=$encoded" -Referer "https://www.instagram.com/explore/tags/$Tag/"

  $mediaItems = New-Object System.Collections.Generic.List[object]
  foreach ($edge in @($payload.data.hashtag.edge_hashtag_to_media.edges)) {
    if ($edge.node) { $mediaItems.Add($edge.node) | Out-Null }
  }
  foreach ($section in @($payload.data.recent.sections + $payload.data.top.sections + $payload.data.additional_data.media_grid.sections)) {
    foreach ($media in @($section.layout_content.medias)) {
      if ($media.media) { $mediaItems.Add($media.media) | Out-Null }
    }
  }

  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($media in @($mediaItems | Select-Object -First $Limit)) {
    $entry = Convert-InstagramMediaToEntry -Media $media -Username ""
    if ($null -ne $entry) { $entries.Add($entry) | Out-Null }
  }
  return @($entries)
}

function Get-InstagramPublishedTime {
  param($Entry, [string]$Fallback)
  if ($Entry.timestamp) {
    try {
      return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Entry.timestamp).ToOffset([TimeSpan]::FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss")
    } catch {}
  }
  if ($Entry.upload_date) {
    try {
      $date = [DateTime]::ParseExact([string]$Entry.upload_date, "yyyyMMdd", [Globalization.CultureInfo]::InvariantCulture)
      return ([DateTimeOffset]$date).ToOffset([TimeSpan]::FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss")
    } catch {}
  }
  return $Fallback
}

function Get-InstagramProfileVideoRows {
  param([string]$ProfileInput, [int]$RequestedCount)

  if ($RequestedCount -lt 1) {
    throw "提取数量必须大于 0"
  }
  if (-not (Test-YtDlpAvailable)) {
    throw "Video download tool was not found."
  }

  $username = Get-InstagramUsernameFromInput -Value $ProfileInput
  $profileUrl = "https://www.instagram.com/$username/"
  $objects = @()
  $ytDlpError = ""
  try {
    $objects = Get-YtDlpJsonObjects -Arguments @(
      "--ignore-errors",
      "--no-warnings",
      "--dump-single-json",
      "--playlist-end",
      [string]$RequestedCount,
      $profileUrl
    )
  } catch {
    $ytDlpError = $_.Exception.Message
  }

  $playlist = $null
  $entries = @()
  $nickname = $username
  $profileVideoCount = 0

  if (@($objects).Count) {
    $playlist = $objects[0]
    if ($playlist.entries) {
      $entries = @($playlist.entries)
    } else {
      $entries = @($objects)
    }
    foreach ($name in @("uploader", "channel", "creator")) {
      if ($playlist.PSObject.Properties[$name].Value) {
        $nickname = [string]$playlist.PSObject.Properties[$name].Value
        break
      }
    }
    $profileVideoCount = if ($playlist.playlist_count) { [int]$playlist.playlist_count } else { @($entries).Count }
  }

  $entries = @($entries | Where-Object { $null -ne $_ } | Select-Object -First $RequestedCount)
  if (-not $entries.Count) {
    try {
      $webInfo = Get-InstagramProfileEntriesFromWebInfo -Username $username -RequestedCount $RequestedCount
      $entries = @($webInfo.Entries | Select-Object -First $RequestedCount)
      $nickname = [string]$webInfo.Nickname
      $profileVideoCount = [int]$webInfo.ProfileVideoCount
    } catch {
      $fallbackError = $_.Exception.Message
      if (-not [string]::IsNullOrWhiteSpace($ytDlpError)) {
        throw "$ytDlpError`n$fallbackError"
      }
      throw $fallbackError
    }
  }

  if (-not $entries.Count) {
    throw "没有找到可导出的 Instagram 视频。"
  }

  if ([string]::IsNullOrWhiteSpace($nickname)) {
    $nickname = $username
  }
  if ($profileVideoCount -lt $entries.Count) {
    $profileVideoCount = $entries.Count
  }

  $snapshot = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss")
  $rows = New-Object System.Collections.Generic.List[object]
  $index = 1
  foreach ($entry in $entries) {
    $link = Get-InstagramLinkFromEntry -Entry $entry
    $videoId = Get-InstagramVideoIdFromLink -Link $link
    if ([string]::IsNullOrWhiteSpace($videoId)) {
      $videoId = [string]$entry.id
    }
    if ([string]::IsNullOrWhiteSpace($link) -and -not [string]::IsNullOrWhiteSpace($videoId)) {
      $link = "https://www.instagram.com/reel/$videoId/"
    }
    $caption = ""
    if ($entry.description) { $caption = ([string]$entry.description).Trim() }
    elseif ($entry.title) { $caption = ([string]$entry.title).Trim() }

    $rows.Add([ordered]@{
      "序号" = $index
      "账号" = "@" + $username
      "账号昵称" = $nickname
      "账号主页" = $profileUrl
      "视频ID" = $videoId
      "发布时间(北京时间)" = (Get-InstagramPublishedTime -Entry $entry -Fallback $snapshot)
      "视频链接" = $link
      "文案" = $caption
      "浏览量" = (ConvertTo-Int64Safe $entry.view_count)
      "点赞量" = (ConvertTo-Int64Safe $entry.like_count)
      "评论数" = (ConvertTo-Int64Safe $entry.comment_count)
      "取数时间(北京时间)" = $snapshot
    }) | Out-Null
    $index++
  }

  return [pscustomobject]@{
    Username = $username
    Nickname = $nickname
    RequestedCount = $RequestedCount
    ProfileVideoCount = $profileVideoCount
    ExtractedCount = $rows.Count
    Rows = [object[]]$rows.ToArray()
  }
}

function Handle-Extract {
  param($Context)
  try {
    $payload = Read-BodyJson -Request $Context.Request
  } catch {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Invalid request data. Please clear the images and try again." }
    return
  }
  $text = ""
  if ($payload -and $payload.text) {
    $text = ([string]$payload.text).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($text)) {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Please enter text." }
    return
  }

  $images = @()
  if ($payload.images) {
    $images = @($payload.images)
  }
  $imageSummary = Get-ImageSummary -Images $images
  $inputSignature = Get-InputSignature -Text $text -Images $images
  $excludeKeys = Get-ExcludedVideoKeys -InputSignature $inputSignature -Text $text -ImageSummary $imageSummary
  $queries = Get-SearchQueries -Text $text -Images $images
  $rows = @(Search-TikTokVideos -Queries $queries -InputText $text -ImageSummary $imageSummary -ExcludeKeys $excludeKeys -TargetCount 15)
  if (-not $rows.Count) {
    Send-Json -Context $Context -Status 502 -Object @{ ok = $false; error = "No new video links were found for this same text and product image. Try changing the keywords or product image." }
    return
  }

  $indexedRows = @()
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $row = $rows[$i]
    $row | Add-Member -NotePropertyName index -NotePropertyValue ($i + 1) -Force
    $indexedRows += $row
  }

  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $namePart = ConvertTo-SafeFileName -Value $text
  $fileName = "video_links_${stamp}_${namePart}.xlsx"
  $filePath = Join-Path $ExportDir $fileName
  New-Xlsx -Rows $indexedRows -Path $filePath

  $entry = [ordered]@{
    id = $stamp
    createdAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    text = $text
    imageCount = @($images).Count
    imageSummary = $imageSummary
    inputSignature = $inputSignature
    rowCount = $indexedRows.Count
    fileName = $fileName
    downloadUrl = "/download/$fileName"
    queries = $queries
    links = @($indexedRows | ForEach-Object { $_.link })
  }
  $history = New-Object System.Collections.Generic.List[object]
  $history.Add([pscustomobject]$entry) | Out-Null
  foreach ($item in @(Get-History)) {
    if ($null -ne $item -and $item.fileName) {
      $history.Add($item) | Out-Null
    }
  }
  Save-History -Items @($history | Select-Object -First 100)

  Send-Json -Context $Context -Status 200 -Object @{
    ok = $true
    count = $indexedRows.Count
    fileName = $fileName
    downloadUrl = "/download/$fileName"
    rows = @($indexedRows | Select-Object index, link, author, title)
    history = $entry
  }
}

function Handle-InstagramLinkExtract {
  param($Context)
  try {
    $payload = Read-BodyJson -Request $Context.Request
  } catch {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Invalid request data. Please clear the images and try again." }
    return
  }
  $text = ""
  if ($payload -and $payload.text) {
    $text = ([string]$payload.text).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($text)) {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Please enter text." }
    return
  }

  $images = @()
  if ($payload.images) {
    $images = @($payload.images)
  }
  $imageSummary = Get-ImageSummary -Images $images
  $inputSignature = Get-InputSignature -Text $text -Images $images
  $excludeKeys = Get-InstagramExcludedVideoKeys -InputSignature $inputSignature -Text $text -ImageSummary $imageSummary
  $tags = Get-InstagramTagQueries -Text $text -Images $images
  $rows = @(Search-InstagramVideos -Tags $tags -InputText $text -ImageSummary $imageSummary -ExcludeKeys $excludeKeys -TargetCount 15)
  if (-not $rows.Count) {
    Send-Json -Context $Context -Status 502 -Object @{ ok = $false; error = "Instagram 当前没有返回可读取的视频链接，可能需要登录、触发频率限制，或公开标签页暂时不可访问。请稍后重试，或允许工具读取浏览器登录态后再试。" }
    return
  }

  $indexedRows = @()
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $row = $rows[$i]
    $row | Add-Member -NotePropertyName index -NotePropertyValue ($i + 1) -Force
    $indexedRows += $row
  }

  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $namePart = ConvertTo-SafeFileName -Value $text
  $fileName = "instagram_video_links_${stamp}_${namePart}.xlsx"
  $filePath = Join-Path $InstagramLinkExportDir $fileName
  New-Xlsx -Rows $indexedRows -Path $filePath

  $entry = [ordered]@{
    id = $stamp
    createdAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    text = $text
    imageCount = @($images).Count
    imageSummary = $imageSummary
    inputSignature = $inputSignature
    rowCount = $indexedRows.Count
    fileName = $fileName
    downloadUrl = "/instagram-link-download/$fileName"
    queries = $tags
    links = @($indexedRows | ForEach-Object { $_.link })
  }
  $history = New-Object System.Collections.Generic.List[object]
  $history.Add([pscustomobject]$entry) | Out-Null
  foreach ($item in @(Get-InstagramLinkHistory)) {
    if ($null -ne $item -and $item.fileName) {
      $history.Add($item) | Out-Null
    }
  }
  Save-InstagramLinkHistory -Items @($history | Select-Object -First 100)

  Send-Json -Context $Context -Status 200 -Object @{
    ok = $true
    count = $indexedRows.Count
    fileName = $fileName
    downloadUrl = "/instagram-link-download/$fileName"
    rows = @($indexedRows | Select-Object index, link, author, title)
    history = $entry
  }
}

function Handle-DeleteHistory {
  param($Context)
  try {
    $payload = Read-BodyJson -Request $Context.Request
  } catch {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Invalid request data." }
    return
  }

  $id = ""
  if ($payload -and $payload.id) {
    $id = ([string]$payload.id).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($id)) {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Missing history id." }
    return
  }

  $history = @(Get-History)
  $target = $history | Where-Object { ([string]$_.id) -eq $id } | Select-Object -First 1
  if ($null -eq $target) {
    Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "History item not found." }
    return
  }

  if ($target.fileName) {
    $fileName = Split-Path -Leaf ([string]$target.fileName)
    $filePath = Join-Path $ExportDir $fileName
    if (Test-Path -LiteralPath $filePath) {
      Remove-Item -LiteralPath $filePath -Force
    }
  }

  $remaining = @($history | Where-Object { ([string]$_.id) -ne $id })
  Save-History -Items $remaining
  Send-Json -Context $Context -Status 200 -Object @{ ok = $true; items = @(Get-History) }
}

function Handle-ProfileExtract {
  param($Context)
  $requestProfileUrl = ""
  $requestCount = 0
  $requestGenerateChart = $false
  $upstreamError = ""

  try {
    $body = Read-BodyText -Request $Context.Request
    if ([string]::IsNullOrWhiteSpace($body)) {
      Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Missing request data." }
      return
    }
    try {
      $requestPayload = $body | ConvertFrom-Json
      if ($requestPayload.profileUrl) { $requestProfileUrl = ([string]$requestPayload.profileUrl).Trim() }
      if ($requestPayload.count) { $requestCount = [int]$requestPayload.count }
      if ($requestPayload.generateChart) { $requestGenerateChart = [bool]$requestPayload.generateChart }
    } catch {}

    try {
      $upstream = Invoke-ProfileToolExtract -Body $body
      if ($upstream.StatusCode -ge 200 -and $upstream.StatusCode -lt 300 -and $upstream.Bytes.Length -gt 0) {
        Add-ProfileHistoryItem -Bytes $upstream.Bytes -Headers $upstream.Headers -ProfileUrl $requestProfileUrl -RequestedCount $requestCount -GenerateChart $requestGenerateChart | Out-Null
        foreach ($name in $upstream.Headers.Keys) {
          $Context.Response.Headers.Add($name, [string]$upstream.Headers[$name])
        }
        $contentType = if ([string]::IsNullOrWhiteSpace($upstream.ContentType)) { "application/octet-stream" } else { $upstream.ContentType }
        Send-Bytes -Context $Context -Status $upstream.StatusCode -ContentType $contentType -Bytes $upstream.Bytes
        return
      }

      if ($upstream.Bytes.Length -gt 0) {
        $upstreamError = [Text.Encoding]::UTF8.GetString($upstream.Bytes)
      } else {
        $upstreamError = "Upstream returned HTTP $($upstream.StatusCode)."
      }
    } catch {
      $upstreamError = $_.Exception.Message
    }

    $result = Get-TikTokProfileVideoRowsLocal -ProfileInput $requestProfileUrl -RequestedCount $requestCount
    $safeName = ConvertTo-StorageFileName -Value "$($result.Nickname).xlsx" -Default "TikTok-profile-data.xlsx"
    $bytes = New-ProfileWorkbookBytes -Rows $result.Rows -SheetName $result.Nickname -IncludeChart:$requestGenerateChart -Platform "TikTok"
    $headers = @{
      "X-Extracted-Count" = [string]$result.ExtractedCount
      "X-Profile-Video-Count" = [string]$result.ProfileVideoCount
      "X-Requested-Count" = [string]$result.RequestedCount
    }
    Add-ProfileHistoryItem -Bytes $bytes -Headers $headers -ProfileUrl $requestProfileUrl -RequestedCount $requestCount -GenerateChart $requestGenerateChart | Out-Null

    $fallbackName = $safeName -replace '[^\x20-\x7E]', "_"
    $encodedName = [Uri]::EscapeDataString($safeName)
    $Context.Response.Headers.Add("Content-Disposition", "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encodedName")
    foreach ($name in $headers.Keys) {
      $Context.Response.Headers.Add($name, [string]$headers[$name])
    }
    Send-Bytes -Context $Context -Status 200 -ContentType "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -Bytes $bytes
  } catch {
    $message = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($upstreamError)) {
      $message = "$upstreamError`n$message"
    }
    Send-Json -Context $Context -Status 500 -Object @{ ok = $false; error = (ConvertTo-FriendlyTikTokError -Message $message) }
  }
}

function Handle-InstagramProfileExtract {
  param($Context)
  try {
    $payload = Read-BodyJson -Request $Context.Request
  } catch {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Invalid request data." }
    return
  }

  $profileUrl = ""
  $count = 0
  $generateChart = $false
  if ($payload -and $payload.profileUrl) { $profileUrl = ([string]$payload.profileUrl).Trim() }
  if ($payload -and $payload.count) { $count = [int]$payload.count }
  if ($payload -and $payload.generateChart) { $generateChart = [bool]$payload.generateChart }

  if (-not (Test-InstagramProfileUrl -Value $profileUrl) -or $count -lt 1) {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "请检查 Instagram 主页链接和提取数量。" }
    return
  }

  try {
    $result = Get-InstagramProfileVideoRows -ProfileInput $profileUrl -RequestedCount $count
    $safeName = ConvertTo-StorageFileName -Value "$($result.Nickname).xlsx" -Default "Instagram-profile-data.xlsx"
    $bytes = New-ProfileWorkbookBytes -Rows $result.Rows -SheetName $result.Nickname -IncludeChart:$generateChart -Platform "Instagram"
    $headers = @{
      "X-Extracted-Count" = [string]$result.ExtractedCount
      "X-Profile-Video-Count" = [string]$result.ProfileVideoCount
      "X-Requested-Count" = [string]$result.RequestedCount
    }
    Add-InstagramProfileHistoryItem -Bytes $bytes -Headers $headers -ProfileUrl $profileUrl -RequestedCount $count -GenerateChart $generateChart -FileName $safeName | Out-Null

    $fallbackName = $safeName -replace '[^\x20-\x7E]', "_"
    $encodedName = [Uri]::EscapeDataString($safeName)
    $Context.Response.Headers.Add("Content-Disposition", "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encodedName")
    foreach ($name in $headers.Keys) {
      $Context.Response.Headers.Add($name, [string]$headers[$name])
    }
    Send-Bytes -Context $Context -Status 200 -ContentType "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -Bytes $bytes
  } catch {
    Send-Json -Context $Context -Status 500 -Object @{ ok = $false; error = (ConvertTo-FriendlyInstagramError -Message $_.Exception.Message) }
  }
}

function Handle-Request {
  param($Context)
  $path = [Uri]::UnescapeDataString($Context.Request.Url.AbsolutePath)
  if ($path -eq "/") { $path = "/index.html" }

  if ($Context.Request.HttpMethod -eq "OPTIONS") {
    Send-Bytes -Context $Context -Status 204 -ContentType "text/plain; charset=utf-8" -Bytes ([byte[]]::new(0))
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/extract") {
    Handle-Extract -Context $Context
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/api/history") {
    Send-Json -Context $Context -Status 200 -Object @{ ok = $true; items = @(Get-History) }
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/history/delete") {
    Handle-DeleteHistory -Context $Context
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/instagram/link-extract") {
    Handle-InstagramLinkExtract -Context $Context
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/api/instagram/link-history") {
    Send-Json -Context $Context -Status 200 -Object @{ ok = $true; items = @(Get-InstagramLinkHistory) }
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/instagram/link-history/delete") {
    Handle-FileHistoryDelete -Context $Context -HistoryPath $InstagramLinkHistoryPath -FileDir $InstagramLinkExportDir
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/profile/extract") {
    Handle-ProfileExtract -Context $Context
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/api/profile/history") {
    Send-Json -Context $Context -Status 200 -Object @{ ok = $true; items = @(Get-ProfileHistory) }
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/profile/history/delete") {
    Handle-FileHistoryDelete -Context $Context -HistoryPath $ProfileHistoryPath -FileDir $ProfileExportDir
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/instagram/profile/extract") {
    Handle-InstagramProfileExtract -Context $Context
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/api/instagram/profile/history") {
    Send-Json -Context $Context -Status 200 -Object @{ ok = $true; items = @(Get-InstagramProfileHistory) }
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/instagram/profile/history/delete") {
    Handle-FileHistoryDelete -Context $Context -HistoryPath $InstagramProfileHistoryPath -FileDir $InstagramProfileExportDir
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/video-file/extract") {
    Handle-VideoFileExtract -Context $Context
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/api/video-file/history") {
    Send-Json -Context $Context -Status 200 -Object @{ ok = $true; items = @(Get-VideoFileHistory) }
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/video-file/history/delete") {
    Handle-FileHistoryDelete -Context $Context -HistoryPath $VideoFileHistoryPath -FileDir $VideoDownloadDir
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/instagram/extract") {
    Handle-InstagramExtract -Context $Context
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path -eq "/api/instagram/history") {
    Send-Json -Context $Context -Status 200 -Object @{ ok = $true; items = @(Get-InstagramHistory) }
    return
  }

  if ($Context.Request.HttpMethod -eq "POST" -and $path -eq "/api/instagram/history/delete") {
    Handle-FileHistoryDelete -Context $Context -HistoryPath $InstagramHistoryPath -FileDir $InstagramDownloadDir
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path.StartsWith("/instagram-profile-download/")) {
    $id = Split-Path -Leaf $path
    $item = @(Get-InstagramProfileHistory) | Where-Object { ([string]$_.id) -eq $id } | Select-Object -First 1
    if ($null -eq $item -or -not $item.storedFileName) {
      Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "File not found." }
      return
    }
    $filePath = Join-Path $InstagramProfileExportDir (Split-Path -Leaf ([string]$item.storedFileName))
    if (-not (Test-Path -LiteralPath $filePath)) {
      Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "File not found." }
      return
    }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    $fileName = ConvertTo-StorageFileName -Value ([string]$item.fileName) -Default "Instagram-profile-data.xlsx"
    $fallbackName = $fileName -replace '[^\x20-\x7E]', "_"
    $encodedName = [Uri]::EscapeDataString($fileName)
    $Context.Response.AddHeader("Content-Disposition", "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encodedName")
    Send-Bytes -Context $Context -Status 200 -ContentType (Get-ContentType -Path $filePath) -Bytes $bytes
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path.StartsWith("/profile-download/")) {
    $id = Split-Path -Leaf $path
    $item = @(Get-ProfileHistory) | Where-Object { ([string]$_.id) -eq $id } | Select-Object -First 1
    if ($null -eq $item -or -not $item.storedFileName) {
      Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "File not found." }
      return
    }
    $filePath = Join-Path $ProfileExportDir (Split-Path -Leaf ([string]$item.storedFileName))
    if (-not (Test-Path -LiteralPath $filePath)) {
      Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "File not found." }
      return
    }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    $fileName = ConvertTo-StorageFileName -Value ([string]$item.fileName) -Default "TikTok-profile-data.xlsx"
    $fallbackName = $fileName -replace '[^\x20-\x7E]', "_"
    $encodedName = [Uri]::EscapeDataString($fileName)
    $Context.Response.AddHeader("Content-Disposition", "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encodedName")
    Send-Bytes -Context $Context -Status 200 -ContentType (Get-ContentType -Path $filePath) -Bytes $bytes
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path.StartsWith("/instagram-link-download/")) {
    $fileName = Split-Path -Leaf $path
    $filePath = Join-Path $InstagramLinkExportDir $fileName
    if (-not (Test-Path -LiteralPath $filePath)) {
      Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "File not found." }
      return
    }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    $fallbackName = $fileName -replace '[^\x20-\x7E]', "_"
    $encodedName = [Uri]::EscapeDataString($fileName)
    $Context.Response.AddHeader("Content-Disposition", "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encodedName")
    Send-Bytes -Context $Context -Status 200 -ContentType (Get-ContentType -Path $filePath) -Bytes $bytes
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path.StartsWith("/instagram-download/")) {
    $fileName = Split-Path -Leaf $path
    $filePath = Join-Path $InstagramDownloadDir $fileName
    if (-not (Test-Path -LiteralPath $filePath) -or ([IO.Path]::GetExtension($filePath).ToLowerInvariant() -ne ".mp4")) {
      Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "File not found." }
      return
    }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    $fallbackName = $fileName -replace '[^\x20-\x7E]', "_"
    $encodedName = [Uri]::EscapeDataString($fileName)
    $Context.Response.AddHeader("Content-Disposition", "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encodedName")
    Send-Bytes -Context $Context -Status 200 -ContentType (Get-ContentType -Path $filePath) -Bytes $bytes
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path.StartsWith("/video-download/")) {
    $fileName = Split-Path -Leaf $path
    $filePath = Join-Path $VideoDownloadDir $fileName
    if (-not (Test-Path -LiteralPath $filePath) -or ([IO.Path]::GetExtension($filePath).ToLowerInvariant() -ne ".mp4")) {
      Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "File not found." }
      return
    }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    $fallbackName = $fileName -replace '[^\x20-\x7E]', "_"
    $encodedName = [Uri]::EscapeDataString($fileName)
    $Context.Response.AddHeader("Content-Disposition", "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encodedName")
    Send-Bytes -Context $Context -Status 200 -ContentType (Get-ContentType -Path $filePath) -Bytes $bytes
    return
  }

  if ($Context.Request.HttpMethod -eq "GET" -and $path.StartsWith("/download/")) {
    $fileName = Split-Path -Leaf $path
    $filePath = Join-Path $ExportDir $fileName
    if (-not (Test-Path -LiteralPath $filePath)) {
      Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "File not found." }
      return
    }
    $bytes = [IO.File]::ReadAllBytes($filePath)
    $fallbackName = $fileName -replace '[^\x20-\x7E]', "_"
    $encodedName = [Uri]::EscapeDataString($fileName)
    $Context.Response.AddHeader("Content-Disposition", "attachment; filename=`"$fallbackName`"; filename*=UTF-8''$encodedName")
    Send-Bytes -Context $Context -Status 200 -ContentType (Get-ContentType -Path $filePath) -Bytes $bytes
    return
  }

  $relative = $path.TrimStart("/")
  if ($relative.Contains("..")) {
    Send-Json -Context $Context -Status 400 -Object @{ ok = $false; error = "Invalid path." }
    return
  }
  $file = Join-Path $Root $relative
  if (-not (Test-Path -LiteralPath $file)) {
    Send-Json -Context $Context -Status 404 -Object @{ ok = $false; error = "Page not found." }
    return
  }
  $bytes = [IO.File]::ReadAllBytes($file)
  Send-Bytes -Context $Context -Status 200 -ContentType (Get-ContentType -Path $file) -Bytes $bytes
}

$listener = New-Object Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "Video link web tool started at $prefix"

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      Handle-Request -Context $context
    } catch {
      try {
        Send-Json -Context $context -Status 500 -Object @{ ok = $false; error = $_.Exception.Message }
      } catch {}
    }
  }
} finally {
  $listener.Stop()
}




