# =====================================================================
# Test-Servers.ps1
#
# Finds PPFSS servers in corp.ads, groups by country, allows selection
# by 4-digit office code, and runs:
#
#   PerformanceTest.ps1 -OfficeId <OfficeId>
#
# Example server name:
#   NZ4001PPFSS01
#
# Country code = NZ
# Office code  = 4001
# OfficeId     = NZ4001
#
# Single-instance protected using an atomic lock folder.
# =====================================================================

# ---------------------------------------------------------------------
# Single Instance Protection
# ---------------------------------------------------------------------

$ScriptInstanceName = "Test-Servers-PPFSS-SpeedTest"

$LockBase = Join-Path $env:ProgramData "Stantec\ScriptLocks"
$LockRoot = Join-Path $LockBase "$ScriptInstanceName.lock"
$PidFile  = Join-Path $LockRoot "pid.txt"
$InfoFile = Join-Path $LockRoot "info.txt"

$LockTaken = $false

try {
    try {
        if (-not (Test-Path $LockBase)) {
            New-Item -Path $LockBase -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        $LockBase = Join-Path $env:TEMP "Stantec-ScriptLocks"
        $LockRoot = Join-Path $LockBase "$ScriptInstanceName.lock"
        $PidFile  = Join-Path $LockRoot "pid.txt"
        $InfoFile = Join-Path $LockRoot "info.txt"

        if (-not (Test-Path $LockBase)) {
            New-Item -Path $LockBase -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
    }

    if (Test-Path $LockRoot) {
        $ExistingPid = $null

        if (Test-Path $PidFile) {
            try {
                $ExistingPid = (Get-Content -Path $PidFile -ErrorAction Stop | Select-Object -First 1).Trim()
            }
            catch {
                $ExistingPid = $null
            }
        }

        if ($ExistingPid -and $ExistingPid -match '^\d+$') {
            $ExistingProcess = Get-Process -Id ([int]$ExistingPid) -ErrorAction SilentlyContinue

            if ($ExistingProcess) {
                Write-Host ""
                Write-Host "ERROR: Another copy of this script is already running." -ForegroundColor Red
                Write-Host "Existing PID : $ExistingPid" -ForegroundColor Yellow
                Write-Host "Process      : $($ExistingProcess.ProcessName)" -ForegroundColor Yellow
                Write-Host "Lock folder  : $LockRoot" -ForegroundColor Yellow
                Write-Host ""
                exit 1
            }
        }

        Write-Host ""
        Write-Host "Stale lock found. Removing old lock folder..." -ForegroundColor Yellow
        Remove-Item -Path $LockRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    try {
        New-Item -Path $LockRoot -ItemType Directory -ErrorAction Stop | Out-Null
        $LockTaken = $true

        $PID | Out-File -FilePath $PidFile -Encoding ascii -Force

        @(
            "ScriptInstanceName=$ScriptInstanceName"
            "PID=$PID"
            "User=$env:USERNAME"
            "Computer=$env:COMPUTERNAME"
            "Started=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "Script=$PSCommandPath"
        ) | Out-File -FilePath $InfoFile -Encoding utf8 -Force
    }
    catch {
        Write-Host ""
        Write-Host "ERROR: Could not create lock folder." -ForegroundColor Red
        Write-Host "Another copy may already be starting or running." -ForegroundColor Yellow
        Write-Host "Lock folder: $LockRoot" -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    # -----------------------------------------------------------------
    # Script Configuration
    # -----------------------------------------------------------------

    $DomainServer = "corp.ads"
    $ServerNameMatch = "*PPFSS*"
    $PerformanceScriptName = "PerformanceTest.ps1"

    $ScriptDirectory = $PSScriptRoot

    if (-not $ScriptDirectory) {
        $ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    if (-not $ScriptDirectory) {
        $ScriptDirectory = (Get-Location).Path
    }

    $PerformanceScriptPath = Join-Path $ScriptDirectory $PerformanceScriptName

    Clear-Host

    Write-Host "PPFSS Server Performance Test Launcher" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    # -----------------------------------------------------------------
    # Validate Performance Script Exists
    # -----------------------------------------------------------------

    if (-not (Test-Path $PerformanceScriptPath)) {
        Write-Host "ERROR: Cannot find performance test script:" -ForegroundColor Red
        Write-Host $PerformanceScriptPath -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    # -----------------------------------------------------------------
    # Load Active Directory Module
    # -----------------------------------------------------------------

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: Failed to load ActiveDirectory PowerShell module." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    # -----------------------------------------------------------------
    # Query Active Directory
    # -----------------------------------------------------------------

    Write-Host "Discovering PPFSS servers in $DomainServer..." -ForegroundColor Cyan
    Write-Host ""

    try {
        $Servers = @(
            Get-ADComputer `
                -Filter "Name -like '$ServerNameMatch'" `
                -Server $DomainServer |
                Select-Object -ExpandProperty Name |
                Sort-Object -Unique
        )
    }
    catch {
        Write-Host "ERROR: Failed to query Active Directory." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    if (-not $Servers -or $Servers.Count -eq 0) {
        Write-Host "No PPFSS servers found." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    # -----------------------------------------------------------------
    # Group Servers by Country Code
    # Country code = first 2 characters of server name
    # -----------------------------------------------------------------

    $CountryServers = @{}

    foreach ($Server in $Servers) {
        if (-not $Server) {
            continue
        }

        $Server = $Server.Trim().ToUpper()

        if ($Server.Length -lt 6) {
            Write-Warning "Skipping server with invalid short name: $Server"
            continue
        }

        $CountryCode = $Server.Substring(0, 2)

        if (-not $CountryServers.ContainsKey($CountryCode)) {
            $CountryServers[$CountryCode] = @()
        }

        $CountryServers[$CountryCode] += $Server
    }

    if ($CountryServers.Count -eq 0) {
        Write-Host "No valid PPFSS server names were found." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    # -----------------------------------------------------------------
    # Display Country Codes
    # -----------------------------------------------------------------

    Write-Host "Available Country Codes" -ForegroundColor Cyan
    Write-Host "=======================" -ForegroundColor Cyan

    $CountryServers.Keys |
        Sort-Object |
        ForEach-Object {
            Write-Host "  $_"
        }

    Write-Host ""

    $SelectedCountryInput = Read-Host "Enter the 2-letter country code"

    if (-not $SelectedCountryInput) {
        Write-Host ""
        Write-Host "ERROR: No country code entered." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    $SelectedCountry = $SelectedCountryInput.Trim().ToUpper()

    if (-not $SelectedCountry) {
        Write-Host ""
        Write-Host "ERROR: No country code entered." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    if (-not $CountryServers.ContainsKey($SelectedCountry)) {
        Write-Host ""
        Write-Host "ERROR: Country code '$SelectedCountry' was not found." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    $SelectedServers = @($CountryServers[$SelectedCountry] | Sort-Object -Unique)

    # -----------------------------------------------------------------
    # Build Office Lookup
    #
    # Example:
    #   NZ4001PPFSS01
    #
    # Country code = first 2 characters
    # Office code  = first 4-digit number found in server name
    # OfficeId     = first 6 characters of server name
    # -----------------------------------------------------------------

    $OfficeLookup = @{}

    foreach ($Server in $SelectedServers) {
        if (-not $Server) {
            continue
        }

        $Server = $Server.Trim().ToUpper()

        if ($Server.Length -lt 6) {
            Write-Warning "Skipping server with invalid short name: $Server"
            continue
        }

        $OfficeId = $Server.Substring(0, 6)

        if ($Server -notmatch '\d{4}') {
            Write-Warning "Skipping server because no 4-digit office code was found: $Server"
            continue
        }

        $OfficeCode = $Matches[0]

        if (-not $OfficeLookup.ContainsKey($OfficeCode)) {
            $OfficeLookup[$OfficeCode] = [PSCustomObject]@{
                OfficeCode = $OfficeCode
                OfficeId   = $OfficeId
                Servers    = @()
            }
        }

        $OfficeLookup[$OfficeCode].Servers += $Server
    }

    if ($OfficeLookup.Count -eq 0) {
        Write-Host ""
        Write-Host "ERROR: No offices with 4-digit office codes were found for $SelectedCountry." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    # -----------------------------------------------------------------
    # Display Offices
    # -----------------------------------------------------------------

    Write-Host ""
    Write-Host "Available Offices for $SelectedCountry" -ForegroundColor Green
    Write-Host "=======================================" -ForegroundColor Green
    Write-Host ""

    foreach ($OfficeCode in ($OfficeLookup.Keys | Sort-Object)) {
        $Office = $OfficeLookup[$OfficeCode]
        Write-Host ("  {0}    {1}" -f $Office.OfficeCode, $Office.OfficeId)
    }

    Write-Host ""
    Write-Host "  0000    Test ALL offices in this country" -ForegroundColor Cyan
    Write-Host ""

    $ChoiceInput = Read-Host "Enter 4-digit office code, or 0000 for all"

    if (-not $ChoiceInput) {
        Write-Host ""
        Write-Host "ERROR: No selection entered." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    $Choice = $ChoiceInput.Trim()

    if (-not $Choice) {
        Write-Host ""
        Write-Host "ERROR: No selection entered." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    # -----------------------------------------------------------------
    # Helper Function: Run Performance Test
    # -----------------------------------------------------------------

    function Invoke-OfficePerformanceTest {
        param (
            [Parameter(Mandatory = $true)]
            [string]$OfficeId,

            [Parameter(Mandatory = $true)]
            [string]$OfficeCode,

            [Parameter(Mandatory = $false)]
            [string[]]$Servers
        )

        Write-Host ""
        Write-Host "==================================================" -ForegroundColor Cyan
        Write-Host "Testing OfficeCode: $OfficeCode"
        Write-Host "Testing OfficeId  : $OfficeId"
        Write-Host "==================================================" -ForegroundColor Cyan

        if ($Servers -and $Servers.Count -gt 0) {
            Write-Host "Matched server(s):" -ForegroundColor DarkCyan

            foreach ($MatchedServer in ($Servers | Sort-Object -Unique)) {
                Write-Host "  $MatchedServer"
            }

            Write-Host ""
        }

        try {
            & $PerformanceScriptPath -OfficeId $OfficeId

            Write-Host ""
            Write-Host "Test completed for $OfficeId." -ForegroundColor Green
        }
        catch {
            Write-Warning "Test failed for OfficeId $OfficeId"
            Write-Warning $_.Exception.Message
        }
    }

    # -----------------------------------------------------------------
    # Run All Offices
    # -----------------------------------------------------------------

    if ($Choice -eq "0000") {
        Write-Host ""
        Write-Host "Running tests for ALL offices in $SelectedCountry..." -ForegroundColor Yellow

        foreach ($OfficeCode in ($OfficeLookup.Keys | Sort-Object)) {
            $Office = $OfficeLookup[$OfficeCode]

            Invoke-OfficePerformanceTest `
                -OfficeId $Office.OfficeId `
                -OfficeCode $Office.OfficeCode `
                -Servers $Office.Servers
        }

        Write-Host ""
        Write-Host "All selected tests completed." -ForegroundColor Green
        Write-Host ""
        exit 0
    }

    # -----------------------------------------------------------------
    # Run One Office
    # -----------------------------------------------------------------

    if ($Choice -notmatch '^\d{4}$') {
        Write-Host ""
        Write-Host "ERROR: Invalid selection '$Choice'." -ForegroundColor Red
        Write-Host "Enter a 4-digit office code, for example 4001, or enter 0000 for all." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    if (-not $OfficeLookup.ContainsKey($Choice)) {
        Write-Host ""
        Write-Host "ERROR: Office code '$Choice' was not found for $SelectedCountry." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    $SelectedOffice = $OfficeLookup[$Choice]

    Invoke-OfficePerformanceTest `
        -OfficeId $SelectedOffice.OfficeId `
        -OfficeCode $SelectedOffice.OfficeCode `
        -Servers $SelectedOffice.Servers

    Write-Host ""
    Write-Host "Script completed." -ForegroundColor Green
    Write-Host ""
    exit 0
}
finally {
    # -----------------------------------------------------------------
    # Release Single Instance Protection
    # -----------------------------------------------------------------

    if ($LockTaken -and (Test-Path $LockRoot)) {
        Remove-Item -Path $LockRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}