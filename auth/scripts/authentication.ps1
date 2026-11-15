# Switches authentication on or off without restarting anything (open_access in identity.yml).
# Windows counterpart of authentication.sh.
#
#   .\auth\scripts\authentication.ps1 off      everybody gets in without logging in, as the
#                                              open_access user (default "guest") in its groups
#                                              (default emondrian-admins): a demo or a trial
#   .\auth\scripts\authentication.ps1 on       logins are required again
#   .\auth\scripts\authentication.ps1 status   prints on or off
#
# Edits only the "enabled:" line of the open_access section (adding the section when missing),
# then applies identity.yml like apply-config.sh: the auth-config container updates Keycloak and
# writes the gateway's config, and the gateway reloads it.

param(
    [Parameter(Position = 0)]
    [ValidateSet("on", "off", "status")]
    [string]$Action
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

if (-not $Action) {
    Get-Content $PSCommandPath | Select-Object -Skip 1 -First 8 | ForEach-Object { $_ -replace '^# ?', '' }
    exit 2
}

# Same file apply-config applies: AUTH_IDENTITY_FILE from the environment or .env
$File = $env:AUTH_IDENTITY_FILE
if (-not $File -and (Test-Path ".env")) {
    $Line = Select-String -Path ".env" -Pattern '^AUTH_IDENTITY_FILE=' | Select-Object -Last 1
    if ($Line) { $File = ($Line.Line -split "=", 2)[1].Trim() }
}
if (-not $File) { $File = "./auth/identity.yml" }
if (-not (Test-Path $File)) { Fail "$File not found (windows-setup.ps1 writes one)" }

# $true when open_access is enabled: a section with enabled: true (or without an enabled line),
# or "open_access: true"
function Get-OpenAccess([string[]]$Lines) {
    $Found = $false; $Inside = $false; $On = $false
    foreach ($L in $Lines) {
        if ($L -match '^open_access:\s*true\s*(#.*)?$') { $Found = $true; $On = $true; $Inside = $false; continue }
        if ($L -match '^open_access:\s*(#.*)?$') { $Found = $true; $On = $true; $Inside = $true; continue }
        if ($Inside -and $L -match '^[^\s#]') { $Inside = $false }
        if ($Inside -and $L -match '^\s+enabled:\s*([^\s#]*)') { $On = ($Matches[1] -eq "true") }
    }
    return ($Found -and $On)
}

function Set-OpenAccess([string[]]$Lines, [bool]$Enabled) {
    $Value = if ($Enabled) { "true" } else { "false" }
    if ($Lines -match '^open_access:\s*(true|false)\s*(#.*)?$') {
        return $Lines | ForEach-Object { $_ -replace '^open_access:\s*(true|false)', "open_access: $Value" }
    }
    if ($Lines -match '^open_access:\s*(#.*)?$') {
        $Result = New-Object System.Collections.Generic.List[string]
        $Inside = $false; $Done = $false
        foreach ($L in $Lines) {
            if ($L -match '^open_access:') { $Inside = $true; $Result.Add($L); continue }
            if ($Inside -and $L -match '^[^\s#]') {
                if (-not $Done) { $Result.Add("  enabled: $Value"); $Done = $true }
                $Inside = $false
            }
            if ($Inside -and $L -match '^(\s+)enabled:') { $Result.Add("$($Matches[1])enabled: $Value"); $Done = $true; continue }
            $Result.Add($L)
        }
        if ($Inside -and -not $Done) { $Result.Add("  enabled: $Value") }
        return $Result.ToArray()
    }
    if (-not $Enabled) { return $Lines }
    return $Lines + @(
        "",
        "# Authentication off: everybody who reaches the server gets in without logging in, as the user",
        "# below in the groups below. Switch with auth/scripts/authentication.ps1 on|off (no restart).",
        "open_access:",
        "  enabled: true",
        "  user: guest",
        "  groups: [emondrian-admins]"
    )
}

$Lines = @(Get-Content -Path $File)

# The switch the gateway reads on each request; the MCP tool set_open_access writes it too
$StateDir = Join-Path (Get-Location) "auth/state"
$StateFile = Join-Path $StateDir "open_access.json"
function Get-StateEnabled {
    if (-not (Test-Path $StateFile)) { return $null }
    $M = Select-String -Path $StateFile -Pattern '"enabled"\s*:\s*(true|false)' | Select-Object -First 1
    if ($M) { return $M.Matches[0].Groups[1].Value -eq "true" }
    return $null
}
function Set-State([bool]$Enabled) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $Value = if ($Enabled) { "true" } else { "false" }
    $Json = "{`n  ""enabled"": $Value,`n  ""changed_by"": ""$env:USERNAME"",`n  ""changed_at"": ""$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"",`n  ""changed_with"": ""authentication.ps1""`n}`n"
    $Tmp = Join-Path $StateDir ".open_access.tmp"
    [System.IO.File]::WriteAllText($Tmp, $Json)
    Move-Item -Force -Path $Tmp -Destination $StateFile
}

if ($Action -eq "status") {
    $State = Get-StateEnabled
    if ($null -eq $State) { $State = Get-OpenAccess $Lines }
    if ($State) { "off" } else { "on" }
    exit 0
}

$WantOpen = ($Action -eq "off")
$NewLines = Set-OpenAccess $Lines $WantOpen
# LF line endings and no BOM, like the file setup wrote
[System.IO.File]::WriteAllText((Resolve-Path $File), (($NewLines -join "`n") + "`n"))
if ((Get-OpenAccess @(Get-Content -Path $File)) -ne $WantOpen) {
    Fail "could not change open_access in $File; edit it by hand"
}
Set-State $WantOpen

# apply-config: identity.yml to Keycloak and the gateway (COMPOSE_FILE in .env includes the
# authentication overlay)
& docker compose build -q auth-config
if ($LASTEXITCODE -ne 0) { Fail "could not build the auth-config image" }
& docker compose run --rm --no-deps auth-config apply
if ($LASTEXITCODE -ne 0) { Fail "identity.yml was not applied (see above)" }
$Gateway = (& docker compose ps -q auth_gateway | Out-String).Trim()
if ($Gateway) {
    # nginx re-reads the config on reload; wait until the old workers are gone
    & docker compose kill -s HUP auth_gateway *> $null
    Start-Sleep -Seconds 1
    for ($i = 0; $i -lt 30; $i++) {
        $Ps = (& docker compose exec -T auth_gateway sh -c 'ps' | Out-String)
        if ($Ps -notmatch 'shutting down') { break }
        Start-Sleep -Seconds 1
    }
    Write-Host "auth gateway reloaded"
}

Write-Host ""
if ($WantOpen) {
    Write-Host "Authentication is OFF: everybody who reaches the server gets in without logging in."
}
else {
    Write-Host "Authentication is ON: logins are required."
    $PublicUrl = ""
    if (Test-Path ".env") {
        $Line = Select-String -Path ".env" -Pattern '^PUBLIC_URL=' | Select-Object -Last 1
        if ($Line) { $PublicUrl = $Line.Line.Substring("PUBLIC_URL=".Length) }
    }
    if ($PublicUrl -like "http://*" -and $PublicUrl -notlike "http://localhost*" -and $PublicUrl -notlike "http://127.0.0.1*") {
        Write-Host "  MCP agents that log in with OAuth from other machines need HTTPS: auth\README.md, HTTPS."
    }
}
