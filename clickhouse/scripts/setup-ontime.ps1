param(
    [switch]$Sample,
    [int]$Year = 0,
    [int[]]$Months = @(),
    [switch]$Full
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClickHouseDir = Split-Path -Parent $ScriptDir
$DataDir = Join-Path $ClickHouseDir "datasets\ontime"

$BaseUrl = "https://transtats.bts.gov/PREZIP/"

function Fail {
    param([string]$Message)

    Write-Host ""
    Write-Error $Message
    exit 1
}

function Write-Step {
    param([string]$Message)

    Write-Host $Message
}

if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

# ============================================================
# Validate arguments
# ============================================================

if ($Sample -and $Full) {
    Fail "Use either -Sample or -Full, not both."
}

if ($Sample -and $Year -ne 0) {
    Fail "Do not combine -Sample with -Year."
}

if ($Full -and $Year -ne 0) {
    Fail "Do not combine -Full with -Year."
}

if ($Months.Count -gt 0 -and $Year -eq 0) {
    Fail "-Months requires -Year."
}

if (-not $Sample -and -not $Full -and $Year -eq 0) {
    $Sample = $true
}

# ============================================================
# Read official BTS file list
# ============================================================

Write-Step "==> [1/3] Reading the official BTS OnTime file list"

$OldProgressPreference = $ProgressPreference
$ProgressPreference = "SilentlyContinue"

try {
    $Response = Invoke-WebRequest `
        -Uri $BaseUrl `
        -UseBasicParsing `
        -ErrorAction Stop
}
catch {
    $ProgressPreference = $OldProgressPreference
    Fail "Failed to read the BTS OnTime file list: $($_.Exception.Message)"
}

$Pattern = 'On_Time_Reporting_Carrier_On_Time_Performance_1987_present_(\d{4})_(\d{1,2})\.zip'

$Matches = [regex]::Matches(
    $Response.Content,
    $Pattern
)

$Files = foreach ($Match in $Matches) {
    [PSCustomObject]@{
        Name  = $Match.Value
        Year  = [int]$Match.Groups[1].Value
        Month = [int]$Match.Groups[2].Value
    }
}

$Files = @(
    $Files |
        Sort-Object Year, Month, Name -Unique
)

# ============================================================
# Select requested files
# ============================================================

if ($Sample) {

    $Files = @(
        $Files |
            Where-Object {
                $_.Year -eq 2022 -and
                $_.Month -eq 1
            }
    )

}
elseif (-not $Full) {

    $Files = @(
        $Files |
            Where-Object {
                $_.Year -eq $Year
            }
    )

    if ($Months.Count -gt 0) {

        $Files = @(
            $Files |
                Where-Object {
                    $Months -contains $_.Month
                }
        )

    }
}

if ($Files.Count -eq 0) {
    $ProgressPreference = $OldProgressPreference
    Fail "No matching BTS OnTime files were found."
}

Write-Host "    Files selected: $($Files.Count)"

# ============================================================
# Download ZIP files
# ============================================================

Write-Step "==> [2/3] Downloading ZIP files"

$DownloadedArchives = @()

foreach ($File in $Files) {

    # Extracted BTS CSV names contain parentheses around
    # "(1987_present)", but year/month remain at the end.
    $ExistingCsv = Get-ChildItem `
        -Path $DataDir `
        -Filter "*.csv" `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "_$($File.Year)_$($File.Month)\.csv$"
        } |
        Select-Object -First 1

    if ($null -ne $ExistingCsv) {

        Write-Host "    Skip (CSV already exists): $($ExistingCsv.Name)"
        continue

    }

    $ZipPath = Join-Path $DataDir $File.Name
    $Url = "$BaseUrl$($File.Name)"

    Write-Host "    Download: $($File.Name)"

    try {

        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $ZipPath `
            -UseBasicParsing `
            -ErrorAction Stop

    }
    catch {

        if (Test-Path $ZipPath) {
            Remove-Item $ZipPath -Force
        }

        $ProgressPreference = $OldProgressPreference

        Fail "Failed to download $($File.Name): $($_.Exception.Message)"
    }

    $DownloadedArchives += $ZipPath
}

# ============================================================
# Extract ZIP files
# ============================================================

Write-Step "==> [3/3] Extracting ZIP files"

foreach ($ZipPath in $DownloadedArchives) {

    Write-Host "    Extract: $(Split-Path -Leaf $ZipPath)"

    try {

        Expand-Archive `
            -LiteralPath $ZipPath `
            -DestinationPath $DataDir `
            -Force

    }
    catch {

        $ProgressPreference = $OldProgressPreference

        Fail "Failed to extract $(Split-Path -Leaf $ZipPath): $($_.Exception.Message)"
    }

    Remove-Item $ZipPath -Force
}

$ProgressPreference = $OldProgressPreference

# ============================================================
# Summary
# ============================================================

$CsvFiles = @(
    Get-ChildItem `
        -Path $DataDir `
        -Filter "*.csv" `
        -File `
        -ErrorAction SilentlyContinue
)

$TotalBytes = (
    $CsvFiles |
        Measure-Object -Property Length -Sum
).Sum

if ($null -eq $TotalBytes) {
    $TotalBytes = 0
}

$DatasetSizeMb = [math]::Round(
    $TotalBytes / 1MB
)

Write-Host ""
Write-Host "Done."
Write-Host "CSV files: $($CsvFiles.Count)"
Write-Host "Dataset size: ${DatasetSizeMb} MB"
Write-Host "Location: $DataDir"
