param(
  [int]$Port = 8788
)

function Test-PortBusy {
  param([int]$Port)
  $client = New-Object Net.Sockets.TcpClient
  try {
    $result = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    $connected = $result.AsyncWaitHandle.WaitOne(180)
    if ($connected) {
      $client.EndConnect($result)
      return $true
    }
    return $false
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Get-PowerShellCommand {
  if ($PSCommandPath) {
    $current = (Get-Process -Id $PID).Path
    if (-not [string]::IsNullOrWhiteSpace($current)) {
      return $current
    }
  }
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) { return $pwsh.Source }
  $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($powershell) { return $powershell.Source }
  throw "PowerShell runtime was not found. Install PowerShell 7 (pwsh) and try again."
}

$script = Join-Path $PSScriptRoot "server.ps1"
$portToUse = $Port
while (Test-PortBusy -Port $portToUse) {
  $portToUse++
}

$arguments = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  $script,
  "-Port",
  [string]$portToUse
)

$startArgs = @{
  FilePath = Get-PowerShellCommand
  ArgumentList = $arguments
  PassThru = $true
}
if ($IsWindows -or $env:OS -eq "Windows_NT") {
  $startArgs.WindowStyle = "Hidden"
}

$process = Start-Process @startArgs

Start-Sleep -Seconds 1
[pscustomobject]@{
  Url = "http://localhost:$portToUse/"
  Pid = $process.Id
  HasExited = $process.HasExited
} | ConvertTo-Json -Compress
