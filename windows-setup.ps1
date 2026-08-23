$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$OnTimeSetup = Join-Path $ScriptDir "clickhouse\scripts\setup-ontime.ps1"

$DockerInstalledByScript = $false

function Write-Header {
    param([string]$Text)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Text
    Write-Host "============================================================"
}

function Fail {
    param([string]$Message)

    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Get-WslVersion {
    # Preferred method:
    # read the installed WSL package version directly.
    # This avoids problems with localized Windows output
    # and Windows PowerShell 5.1 console encoding.
    try {
        $WslPackage = Get-AppxPackage `
            -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" `
            -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if (
            $null -ne $WslPackage -and
            $null -ne $WslPackage.Version
        ) {
            return [version]$WslPackage.Version.ToString()
        }
    }
    catch {
        # Fall back to wsl.exe below.
    }

    # Fallback method.
    try {
        $Output = & wsl.exe --version 2>&1

        if ($LASTEXITCODE -ne 0) {
            return $null
        }

        # Windows PowerShell 5.1 may preserve NUL characters
        # in output produced by native Windows applications.
        $Text = (($Output -join "`n") -replace "`0", "")

        $Match = [regex]::Match(
            $Text,
            '\d+\.\d+\.\d+(?:\.\d+)?'
        )

        if (-not $Match.Success) {
            return $null
        }

        return [version]$Match.Value
    }
    catch {
        return $null
    }
}

function Invoke-ElevatedWsl {
    param(
        [string[]]$Arguments
    )

    try {
        $Process = Start-Process `
            -FilePath "wsl.exe" `
            -Verb RunAs `
            -Wait `
            -PassThru `
            -ArgumentList $Arguments

        return $Process.ExitCode
    }
    catch {
        Fail "Administrator permission is required to configure WSL."
    }
}

function Ensure-Wsl {
    Write-Header "Checking WSL 2"

    $MinimumVersion = [version]"2.1.5"
    $WslVersion = Get-WslVersion

    if ($null -eq $WslVersion) {
        Write-Host "WSL: not installed or too old"
        Write-Host "Installing WSL without an additional Linux distribution..."

        $ExitCode = Invoke-ElevatedWsl @(
            "--install",
            "--no-distribution"
        )

        if ($ExitCode -ne 0 -and $ExitCode -ne 3010) {
            Fail "WSL installation failed with exit code $ExitCode."
        }

        $WslVersion = Get-WslVersion

        if ($ExitCode -eq 3010 -or $null -eq $WslVersion) {
            Write-Host ""
            Write-Host "WSL installation requires a Windows restart."
            Write-Host ""
            Write-Host "Restart Windows and run this command again:"
            Write-Host ""
            Write-Host "  powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1"
            Write-Host ""
            exit 0
        }
    }

    if ($WslVersion -lt $MinimumVersion) {
        Write-Host "WSL version: $WslVersion"
        Write-Host "Updating WSL..."

        $ExitCode = Invoke-ElevatedWsl @(
            "--update"
        )

        if ($ExitCode -ne 0 -and $ExitCode -ne 3010) {
            Fail "WSL update failed with exit code $ExitCode."
        }

        $WslVersion = Get-WslVersion

        if (
            $ExitCode -eq 3010 -or
            $null -eq $WslVersion
        ) {
            Write-Host ""
            Write-Host "WSL update requires a Windows restart."
            Write-Host ""
            Write-Host "Restart Windows and run:"
            Write-Host ""
            Write-Host "  powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1"
            Write-Host ""
            exit 0
        }

        if ($WslVersion -lt $MinimumVersion) {
            Fail "WSL version $WslVersion is too old. Docker Desktop requires WSL $MinimumVersion or newer."
        }
    }

    Write-Host "WSL version: $WslVersion"
    Write-Host "WSL: OK"
}

function Refresh-DockerPath {
    $PossiblePaths = @(
        (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\bin"),
        (Join-Path $env:ProgramFiles "Docker\Docker\resources\bin")
    )

    foreach ($Path in $PossiblePaths) {
        if (
            (Test-Path $Path) -and
            ($env:Path -notlike "*$Path*")
        ) {
            $env:Path = "$Path;$env:Path"
        }
    }
}

function Get-DockerDesktopExecutable {
    $PossiblePaths = @(
        (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\Docker Desktop.exe"),
        (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe")
    )

    foreach ($Path in $PossiblePaths) {
        if (Test-Path $Path) {
            return $Path
        }
    }

    return $null
}

function Test-DockerDaemon {
    try {
        & docker info *> $null

        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Install-DockerDesktop {
    Write-Header "Installing Docker Desktop"

    if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
        Fail "Automatic Windows setup currently supports x86_64/AMD64 PCs only."
    }

    Write-Host "Docker Desktop will be installed in per-user mode."
    Write-Host "The WSL 2 backend and Linux containers will be used."
    Write-Host ""
    Write-Host "Continuing means accepting the Docker Subscription Service Agreement."
    Write-Host ""

    $Answer = Read-Host "Install Docker Desktop and accept its license? [y/N]"

    if (
        $Answer -ne "y" -and
        $Answer -ne "Y" -and
        $Answer -ne "yes" -and
        $Answer -ne "YES"
    ) {
        Fail "Docker Desktop installation was cancelled."
    }

    $Installer = Join-Path `
        $env:TEMP `
        "Docker Desktop Installer.exe"

    $InstallerUrl = `
        "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"

    Write-Host "Downloading Docker Desktop..."

    $OldProgressPreference = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"

    try {
        Invoke-WebRequest `
            -Uri $InstallerUrl `
            -OutFile $Installer `
            -UseBasicParsing `
            -ErrorAction Stop
    }
    catch {
        $ProgressPreference = $OldProgressPreference

        if (Test-Path $Installer) {
            Remove-Item $Installer -Force -ErrorAction SilentlyContinue
        }

        Fail "Failed to download Docker Desktop: $($_.Exception.Message)"
    }

    $ProgressPreference = $OldProgressPreference

    Write-Host "Installing Docker Desktop..."

    try {
        $Process = Start-Process `
            -FilePath $Installer `
            -Wait `
            -PassThru `
            -ArgumentList @(
                "install",
                "--user",
                "--quiet",
                "--accept-license",
                "--backend=wsl-2",
                "--no-windows-containers"
            )
    }
    catch {
        Remove-Item $Installer -Force -ErrorAction SilentlyContinue
        Fail "Failed to start Docker Desktop installer: $($_.Exception.Message)"
    }

    Remove-Item $Installer -Force -ErrorAction SilentlyContinue

    if ($Process.ExitCode -ne 0) {
        Fail "Docker Desktop installation failed with exit code $($Process.ExitCode)."
    }

    $script:DockerInstalledByScript = $true

    Refresh-DockerPath

    if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
        Fail "Docker Desktop was installed, but docker.exe could not be found."
    }

    Write-Host "Docker Desktop installed successfully."
}

function Ensure-DockerDesktop {
    Write-Header "Checking Docker"

    Refresh-DockerPath

    $DockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
    $DockerDesktop = Get-DockerDesktopExecutable

    if ($null -eq $DockerCommand -and $null -eq $DockerDesktop) {
        Write-Host "Docker Desktop: not found"

        Install-DockerDesktop

        return
    }

    if ($null -eq $DockerDesktop) {
        if (Test-DockerDaemon) {
            Write-Host "Docker daemon is already available."
            return
        }

        Write-Host "Docker CLI was found, but Docker Desktop was not."
        Write-Host "Installing Docker Desktop..."

        Install-DockerDesktop
        return
    }

    Write-Host "Docker Desktop: found"
}

function Start-DockerDesktopAndWait {
    Write-Host "Checking Docker daemon..."

    Refresh-DockerPath

    if (Test-DockerDaemon) {
        Write-Host "Docker daemon: OK"
        return
    }

    $DockerDesktop = Get-DockerDesktopExecutable

    if ($null -eq $DockerDesktop) {
        Fail "Docker Desktop executable was not found."
    }

    Write-Host "Starting Docker Desktop..."

    Start-Process `
        -FilePath $DockerDesktop `
        | Out-Null

    $MaxAttempts = 300

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
        if (Test-DockerDaemon) {
            Write-Host "Docker daemon: OK"
            return
        }

        if (($Attempt % 10) -eq 0) {
            Write-Host "Waiting for Docker Desktop... ${Attempt}s"
        }

        Start-Sleep -Seconds 1
    }

    Write-Host ""
    Write-Host "Docker Desktop did not become ready."
    Write-Host "If WSL was installed or enabled for the first time, restart Windows"
    Write-Host "and run windows-setup.ps1 again."
    Write-Host ""

    Fail "Docker daemon did not become ready after $MaxAttempts seconds."
}

function Ensure-DockerCompose {
    & docker compose version *> $null

    if ($LASTEXITCODE -ne 0) {
        Fail "Docker Compose plugin is not available."
    }

    Write-Host "Docker: $(& docker --version)"
    Write-Host "Docker Compose: $(& docker compose version --short)"
}

# ============================================================
# Start
# ============================================================

Write-Header "eMondrian Community Quick Start"

if ($env:OS -ne "Windows_NT") {
    Fail "This script is intended for Windows. Use setup.sh on Linux."
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Fail "PowerShell 5.1 or newer is required."
}

try {
    $Os = Get-CimInstance Win32_OperatingSystem

    Write-Host "Windows: $($Os.Caption)"
    Write-Host "Version: $($Os.Version)"
}
catch {
    Write-Host "Windows detected."
}

Write-Host "Architecture: $env:PROCESSOR_ARCHITECTURE"

# ============================================================
# Validate project files
# ============================================================

Write-Header "Checking project files"

$RequiredFiles = @(
    ".env.example",
    "docker-compose.yml",
    "datasources.xml",
    "schema\Foodmart.xml",
    "schema\OnTime.xml",
    "clickhouse\init-scripts\init-ontime.sh",
    "clickhouse\scripts\setup-ontime.ps1"
)

foreach ($File in $RequiredFiles) {
    $FullPath = Join-Path $ScriptDir $File

    if (-not (Test-Path $FullPath)) {
        Fail "$File was not found."
    }
}

Write-Host "Project files: OK"

# ============================================================
# Prepare environment file
# ============================================================

$EnvFile = Join-Path $ScriptDir ".env"
$EnvExample = Join-Path $ScriptDir ".env.example"

if (-not (Test-Path $EnvFile)) {
    Write-Host "Creating .env from .env.example..."

    Copy-Item `
        -Path $EnvExample `
        -Destination $EnvFile

    Write-Host ".env: created"
}
else {
    Write-Host ".env: already exists"
}

# ============================================================
# Web front door port
# ============================================================

# Shell environment wins over .env, matching how Docker Compose itself
# resolves ${EMONDRIAN_PORT}.
$EmondrianPort = $env:EMONDRIAN_PORT

if ([string]::IsNullOrWhiteSpace($EmondrianPort) -and (Test-Path $EnvFile)) {
    $PortLine = Select-String -Path $EnvFile -Pattern '^\s*EMONDRIAN_PORT\s*=' |
        Select-Object -Last 1

    if ($null -ne $PortLine) {
        $EmondrianPort = ($PortLine.Line -split "=", 2)[1].Trim().Trim('"').Trim("'")
    }
}

if ([string]::IsNullOrWhiteSpace($EmondrianPort)) {
    $EmondrianPort = "80"
}

$PortNumber = 0

if (
    -not [int]::TryParse($EmondrianPort, [ref]$PortNumber) -or
    $PortNumber -lt 1 -or
    $PortNumber -gt 65535
) {
    Fail "EMONDRIAN_PORT must be a port number, got: $EmondrianPort"
}

# Compose reads .env by itself; exporting this makes an EMONDRIAN_PORT passed
# in the environment reach Compose as well.
$env:EMONDRIAN_PORT = $PortNumber

$WebUrl = "http://localhost:$PortNumber/"

if ($PortNumber -eq 80) {
    $WebBase = "http://localhost"
}
else {
    $WebBase = "http://localhost:$PortNumber"
}

Write-Host "Web front door port: $PortNumber"

# ============================================================
# WSL
# ============================================================

Ensure-Wsl

# ============================================================
# Docker Desktop
# ============================================================

Ensure-DockerDesktop
Start-DockerDesktopAndWait
Ensure-DockerCompose

# ============================================================
# Validate Docker Compose
# ============================================================

Write-Header "Checking Docker Compose configuration"

& docker compose config *> $null

if ($LASTEXITCODE -ne 0) {
    Fail "docker-compose.yml is invalid."
}

Write-Host "Docker Compose configuration: OK"

# ============================================================
# Download OnTime sample
# ============================================================

Write-Header "Preparing OnTime sample dataset"

& $OnTimeSetup -Sample

# ============================================================
# Start containers
# ============================================================

Write-Header "Starting containers"

# Refuse early if something else holds the port. Without this the failure
# arrives as a raw compose bind error, or later as a timeout that blames the
# wrong thing. A container of ours already on it is just a re-run - compare the
# published binding, not merely whether the container is up, because with a
# changed port it is up on the old one.
$PortInUse = $false

try {
    $TcpClient = New-Object System.Net.Sockets.TcpClient
    $PortInUse = $TcpClient.ConnectAsync("127.0.0.1", $PortNumber).Wait(1000)
    $TcpClient.Close()
}
catch {
    $PortInUse = $false
}

if ($PortInUse) {
    $OwnBinding = ""

    try {
        $OwnBinding = (& docker compose port emondrian_entry 80 | Out-String).Trim()
    }
    catch {
        $OwnBinding = ""
    }

    if ($OwnBinding -notmatch ":$PortNumber$") {
        Fail @"
Port $PortNumber is already in use by another program.

Free it, or pick a different port by setting EMONDRIAN_PORT in .env:

    EMONDRIAN_PORT=8081

Then run this script again.
"@
    }
}

& docker compose up -d

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Docker Compose failed."

    Write-Host ""
    Write-Host "ClickHouse logs:"
    & docker compose logs --tail=50 clickhouse

    Write-Host ""
    Write-Host "OnTime initialization logs:"
    & docker compose logs ontime-init

    Write-Host ""
    Write-Host "eMondrian logs:"
    & docker compose logs --tail=50 eMondrian

    Fail "Failed to start eMondrian Community."
}

# ============================================================
# Verify ClickHouse
# ============================================================

Write-Header "Checking ClickHouse"

& docker compose exec -T clickhouse `
    clickhouse-client `
    --query="SELECT 1" `
    *> $null

if ($LASTEXITCODE -ne 0) {
    & docker compose logs --tail=50 clickhouse

    Fail "ClickHouse is not available."
}

Write-Host "ClickHouse: OK"

# ============================================================
# Verify OnTime initialization
# ============================================================

Write-Host "Checking OnTime initialization..."

$OnTimeInitContainer = (
    & docker compose ps -aq ontime-init
).Trim()

if ([string]::IsNullOrWhiteSpace($OnTimeInitContainer)) {
    Fail "OnTime initialization container was not created."
}

$OnTimeExitCode = (
    & docker inspect `
        --format='{{.State.ExitCode}}' `
        $OnTimeInitContainer
).Trim()

if ($OnTimeExitCode -ne "0") {
    Write-Host ""

    & docker compose logs ontime-init

    Fail "OnTime initialization failed with exit code $OnTimeExitCode."
}

Write-Host "OnTime initialization: OK"

# ============================================================
# Verify OnTime data
# ============================================================

$OnTimeRows = (
    & docker compose exec -T clickhouse `
        clickhouse-client `
        --query="SELECT count() FROM ontime"
).Trim()

if ([string]::IsNullOrWhiteSpace($OnTimeRows)) {
    Fail "Could not read the OnTime row count."
}

$OnTimeRowCount = [long]$OnTimeRows

if ($OnTimeRowCount -eq 0) {
    Fail "OnTime table does not contain any rows."
}

Write-Host "OnTime rows: $($OnTimeRowCount.ToString('N0'))"

# ============================================================
# Wait for eMondrian
# ============================================================

Write-Header "Waiting for eMondrian"

$MaxAttempts = 120

for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
    $EmondrianContainer = (
        & docker compose ps -aq eMondrian
    ).Trim()

    if ([string]::IsNullOrWhiteSpace($EmondrianContainer)) {
        & docker compose logs --tail=100 eMondrian

        Fail "eMondrian container was not created."
    }

    $Health = (
        & docker inspect `
            --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' `
            $EmondrianContainer
    ).Trim()

    if ($Health -eq "healthy") {
        break
    }

    if (
        $Health -eq "unhealthy" -or
        $Health -eq "exited" -or
        $Health -eq "dead"
    ) {
        Write-Host ""

        & docker compose logs --tail=100 eMondrian

        Fail "eMondrian failed to start. Status: $Health."
    }

    if ($Attempt -eq $MaxAttempts) {
        Write-Host ""

        & docker compose logs --tail=100 eMondrian

        Fail "eMondrian did not become healthy after $MaxAttempts seconds."
    }

    Start-Sleep -Seconds 1
}

Write-Host "eMondrian: healthy"

# ============================================================
# Wait for the web front door
# ============================================================

Write-Header "Waiting for the web interface"

$MaxAttempts = 60
$WebReady = $false

for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
    try {
        Invoke-WebRequest `
            -Uri $WebUrl `
            -UseBasicParsing `
            -TimeoutSec 5 | Out-Null

        $WebReady = $true
        break
    }
    catch {
        Start-Sleep -Seconds 1
    }
}

if (-not $WebReady) {
    Write-Host ""

    & docker compose logs --tail=50 emondrian_entry

    Write-Host ""
    Write-Host "The engine is running, but $WebUrl is not responding."
    Write-Host "Common causes: the web container failed to start (see its log above),"
    Write-Host "or another program is already using port $PortNumber."

    Fail "The web interface did not come up after $MaxAttempts seconds."
}

Write-Host "Web interface: OK"

# ============================================================
# Finished
# ============================================================

Write-Header "eMondrian Community is ready"

Write-Host "Web interface:"
Write-Host "  $WebBase"
Write-Host ""

Write-Host "XMLA endpoint:"
Write-Host "  $WebBase/xmla"
Write-Host ""

Write-Host "Available catalogs:"
Write-Host "  - FoodMart"
Write-Host "  - OnTime"
Write-Host ""

Write-Host "OnTime rows:"
Write-Host "  $($OnTimeRowCount.ToString('N0'))"
Write-Host ""

Write-Host "Containers:"
& docker compose ps
Write-Host ""

if ($DockerInstalledByScript) {
    Write-Host "Docker Desktop was installed automatically."
    Write-Host ""
}