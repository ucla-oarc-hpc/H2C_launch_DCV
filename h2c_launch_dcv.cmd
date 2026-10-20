<# : batch section (cmd.exe runs this part; PowerShell treats it as a comment)
@echo off
setlocal
set "H2C_SCRIPT=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ([ScriptBlock]::Create([IO.File]::ReadAllText($env:H2C_SCRIPT))) %*"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
#>
#
# h2c_launch_dcv.cmd - Connect to a DCV virtual session on Hoffman2 from Windows.
#
# Single-file batch/PowerShell hybrid: double-click it, or run from cmd or PowerShell:
#     .\h2c_launch_dcv.cmd -User joebruin
#     .\h2c_launch_dcv.cmd -Help
#
param(
    [string]$User = $env:USERNAME,
    [Alias('h')]
    [switch]$Help
)

# --- CONFIGURATION DEFAULT VALUES ---
$DcvHost            = 'dcv1.hoffman2.oarc.ucla.edu'   # Plain hostname or IP only
$DcvPort            = 8443
$ViewerGraceSeconds = 15                              # Time the viewer has to read the .dcv file before it is wiped
$DcvDownloadUrl     = 'https://www.amazondcv.com/'
# ------------------------------------

$ErrorActionPreference = 'Stop'

function Show-Usage {
    Write-Host @"
Usage: h2c_launch_dcv.cmd [-User username] [-Help]

Connect to a DCV virtual session on $DcvHost, creating the session first
if it does not exist yet. The session is named '<username>-dcv'.

Options:
  -User username   Username on $DcvHost (default: '$env:USERNAME')
  -Help, -h        Show this help and exit

Requirements:
  - Windows OpenSSH client (ssh.exe), included with Windows 10 1809+ and Windows 11
  - The DCV Viewer for Windows
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

# Reject anything that is not a plain POSIX username (also blocks values that ssh would parse as options)
if ($User -cnotmatch '^[a-z_][a-z0-9._-]*$') {
    Write-Host "ERROR: Invalid username '$User'." -ForegroundColor Red
    Write-Host "Pass your Hoffman2 username explicitly, e.g.:  h2c_launch_dcv.cmd -User joebruin"
    exit 1
}

function Find-Viewer {
    $cmd = Get-Command dcvviewer.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($root in $roots) {
        foreach ($vendor in 'NICE', 'Amazon') {
            $candidate = Join-Path $root "$vendor\DCV\Client\bin\dcvviewer.exe"
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

# Check prerequisites before touching the server
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "ERROR: The OpenSSH client (ssh.exe) was not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Install it from Settings > System > Optional features > Add a feature > 'OpenSSH Client',"
    Write-Host "or from an administrator PowerShell:"
    Write-Host "    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    Write-Host ""
    exit 1
}

$Viewer = Find-Viewer
if (-not $Viewer) {
    Write-Host ""
    Write-Host "ERROR: The DCV Viewer was not found on this computer." -ForegroundColor Red
    Write-Host ""
    Write-Host "Download it from: $DcvDownloadUrl  (Clients section)"
    Write-Host ""
    Write-Host "Windows:"
    Write-Host "  Download the Windows client (.msi installer, or the portable .zip),"
    Write-Host "  install it, then re-run this script."
    Write-Host "  If you used the portable version or a non-default folder, add the folder"
    Write-Host "  that contains dcvviewer.exe to your PATH."
    Write-Host ""
    exit 1
}
Write-Host "Using DCV Viewer: $Viewer"

# Session IDs are unique server-wide, so derive one per user
$SessionId = "$User-dcv"

Write-Host "Using target username: '$User'"

Write-Host "=========================================================="
Write-Host " Connecting to $DcvHost ..."
Write-Host "=========================================================="

# 1-2. Check for the session and create it if missing, all in one SSH login.
#      Wrapped in 'bash -c' because the remote login shell may be tcsh.
#      The command contains no double quotes (Windows PowerShell 5.1 mangles them
#      when passing arguments to native programs); $SessionId is validated above.
$remote = "bash -c 'if dcv describe-session $SessionId >/dev/null 2>&1; then echo DCV_EXISTS; " +
          "else dcv create-session --type virtual $SessionId >/dev/null 2>&1 && sleep 2 && " +
          "dcv describe-session $SessionId >/dev/null 2>&1 && echo DCV_CREATED; fi'"

$output = & ssh.exe "$User@$DcvHost" $remote
if ($LASTEXITCODE -eq 255) {
    Write-Host "ERROR: SSH connection to $DcvHost failed. Exiting." -ForegroundColor Red
    exit 1
}

if ($output -contains 'DCV_EXISTS') {
    Write-Host "Existing DCV session '$SessionId' found."
} elseif ($output -contains 'DCV_CREATED') {
    Write-Host "Created a new virtual session '$SessionId'."
} else {
    Write-Host "ERROR: Failed to spin up the DCV session." -ForegroundColor Red
    exit 1
}

# 3. Generate the temporary .dcv connection file (no password: the viewer prompts for it)
Write-Host "Generating temporary connection file..."
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dcv-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $TempDir | Out-Null
$TempDcvFile = Join-Path $TempDir 'connect.dcv'

@"
[version]
format=1.0

[connect]
host=$DcvHost
port=$DcvPort
sessionid=$SessionId
user=$User
proxytype=NONE
transport=auto

[options]
fullscreen=false
useallmonitors=false
"@ | Set-Content -LiteralPath $TempDcvFile -Encoding ASCII

# 4. Launch the viewer targeting the file
Write-Host "Launching DCV Viewer..."
Start-Process -FilePath $Viewer -ArgumentList "`"$TempDcvFile`""

# 5. Wipe the connection file once the viewer has had time to read it.
#    Done in a hidden detached process so this window is released immediately.
$psExe      = (Get-Process -Id $PID).Path
$quotedDir  = $TempDir -replace "'", "''"
$cleanupCmd = "Start-Sleep -Seconds $ViewerGraceSeconds; Remove-Item -LiteralPath '$quotedDir' -Recurse -Force -ErrorAction SilentlyContinue"
Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $cleanupCmd

exit 0
