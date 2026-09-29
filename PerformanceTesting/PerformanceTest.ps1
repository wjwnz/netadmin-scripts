# ==========================================
# Performance Test Script - Outlook Email Version
# ==========================================
# Created by bill.walker2@stantec.com
# Last Modified 17th June 2026
# Version 1.2
# Added more error checking and Preffered Gateway
# Added Latency
# Added Dynamic File sizing
# To Do:
#    If Connected to VPN ask what ISP they are using
# 
# \\XXXXXX-PPFSS01\networktest$
# ==========================================
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
# powershell -executionpolicy bypass -file script.ps1
# [__ComObject].InvokeMember('SiteName', 'GetProperty', $null, (New-Object -ComObject ADSystemInfo), $null)
# -----------------------------
# CONFIG
# -----------------------------
param(
    [string]$OfficeId, 
    [string]$debug
)
$localFolder = "C:\Temp"
$localLogFolder = "C:\LOGS"

$testFileName = "PerformanceTestSample.bin"
# $resultsRecipient = "e86678f5.stantec.com@amer.teams.ms"
$resultsRecipient = "netperf@stantec.onmicrosoft.com"
$emailPrefix = "[NETPERF]"

# -----------------------------
# INIT
# -----------------------------
New-Item -Path $localFolder -ItemType Directory -Force | Out-Null
New-Item -Path $localLogFolder -ItemType Directory -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runId = "$timestamp-$env:COMPUTERNAME-$env:USERNAME"

$testFileName = "PerformanceTestSample-$runId.bin"

$localTestFile = Join-Path $localFolder $testFileName
$localCsvFile  = Join-Path $localFolder "PerfTest-$runId.csv"
$localLogFile  = Join-Path $localLogFolder "PerfTest-$runId.log"

# -----------------------------
# LOGGING
# -----------------------------
function Write-Log {
    param($msg, $level)

    if ([string]::IsNullOrWhiteSpace($level)) {
        $level = "INFO"
    }

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
    Write-Host $line
    Add-Content -Path $localLogFile -Value $line
}

# -----------------------------
# DEBUGING
# -----------------------------
function Write-Debug {
    param($msg, $level)

    if ($debug) {
    	if ([string]::IsNullOrWhiteSpace($level)) {
        	$level = "DEBUG"
		}

	    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg
	    Write-Host $line
	    Add-Content -Path $localLogFile -Value $line
    }
}

# -----------------------------
# SPEED PARSER (FIXED)
# -----------------------------
function Parse-Speed {
    param ($output)

    $line = $output | Where-Object { $_ -match "Bytes/sec" } | Select-Object -Last 1

    if (-not $line) {
        return @{
            Raw="Not found"
            MBps=""
            Mbitps=""
        }
    }

    if ($line -match "([\d,\.]+)\s+Bytes/sec") {
        $bytes = ($matches[1] -replace '[^\d]')

        if ($bytes) {
            $megabytesps = [math]::Round($bytes / 1MB, 2)
            $mbit = ([math]::Round(($bytes) / 1MB, 2))*8

            return @{
                Raw=$line.Trim()
                MBps=$megabytesps
                Mbitps=$mbit
            }
        }
    }

    return @{
        Raw=$line
        MBps=""
        Mbitps=""
    }
}

# -----------------------------
# LATENCY
# -----------------------------
function Test-Latency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [int]$Count = 4
    )

    try {
        $pings = Test-Connection -ComputerName $ComputerName -Count $Count -ErrorAction Stop

        $latencies = @(
            $pings | ForEach-Object {
                if ($_.PSObject.Properties['Latency']) {
                    $_.Latency
                }
                elseif ($_.PSObject.Properties['ResponseTime']) {
                    $_.ResponseTime
                }
            }
        ) | Where-Object { $null -ne $_ }

        if ($latencies.Count -eq 0) {
            return $null
        }

        return [Math]::Round(
			(($latencies | Measure-Object -Average).Average),
			2
		)
    }
    catch {
        Write-Log "Latency test failed: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# -----------------------------
# VPN
# -----------------------------
function Get-VPNStatus {
    $vpn = Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -like "PANGP*" -and $_.Status -eq "Up"
    }
    return [bool]$vpn
}

function Get-Gateway {

    $file = "C:\Program Files\Palo Alto Networks\GlobalProtect\PanGPS.log"

    if (-not (Test-Path $file)) {
        return "Unknown"
    }

    $content = Get-Content $file -Tail 10000

    # Find currently connected gateway
    $gatewayLine = $content |
        Select-String "Gateway: " |
        Select-Object -Last 1

    if ($gatewayLine -notmatch "Gateway:\s+([^,\s]+)") {
        return "Unknown"
    }

    $currentGateway = $matches[1]

    # Find friendly name entry
	foreach ($line in $content) {

		if ($line -match "^.*Gateway\s+(\S+)\(([^)]+)\):") {

			$gateway = $matches[1]
			$friendlyName = $matches[2]

			if ($gateway -eq $currentGateway) {
				$gatewayCode = $gateway -replace '\.vpn\.stantec\.com$',''
				return "$friendlyName ($gatewayCode)"
			}
		}
	}

return $currentGateway
}

function Get-PreferredGateway {

    $prefFile = "C:\LOGS\SetGPGateway.log"
    $gpsFile  = "C:\Program Files\Palo Alto Networks\GlobalProtect\PanGPS.log"

    if (-not (Test-Path $prefFile)) {
        return "Unknown"
    }

    $line = Get-Content $prefFile -Tail 200 |
        Select-String 'PreferredGateway set to:|Gateway already set to' |
        Select-Object -Last 1

    if ($null -eq $line) {
        return "Unknown"
    }

    $preferredName = $null

    if ($line -match 'PreferredGateway set to:\s*(.+)$') {
        $preferredName = $matches[1].Trim()
    }
    elseif ($line -match 'Gateway already set to\s*([^,]+)') {
        $preferredName = $matches[1].Trim()
    }

    if (-not $preferredName) {
        return "Unknown"
    }

    if (-not (Test-Path $gpsFile)) {
        return $preferredName
    }

    foreach ($logLine in (Get-Content $gpsFile -Tail 10000)) {

        if ($logLine -match 'Gateway\s+(\S+)\(([^)]+)\):') {

            $gatewayFqdn  = $matches[1]
            $friendlyName = $matches[2]

            if ($friendlyName -eq $preferredName) {

                $gatewayCode = $gatewayFqdn -replace '\.vpn\.stantec\.com$',''

                return "$friendlyName ($gatewayCode)"
            }
        }
    }

    return $preferredName
}



# -----------------------------
# INPUT
# -----------------------------

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "This script should be run as a regular user"
Write-Host "It will attempt to write a file to a test UNC path on the local file server in the office you specify"
Write-Host "On completion it will store the results in C:\LOGS and email them to the network team"
Write-Debug "File Name: $testFileName"
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host

# If no OfficeId supplied by calling script, prompt user
if (-not $OfficeId)
{
    do
    {
        $OfficeId = Read-Host "Enter Office ID (e.g. NZ4100)"
        $OfficeId = $OfficeId.Trim()

        if ($OfficeId -notmatch '^[a-zA-Z]{2}\d{4}$')
        {
            Write-Host "Invalid Office ID format. Expected NZ4100" -ForegroundColor Yellow
            $OfficeId = $null
        }

    } until ($OfficeId)
}

$OfficeId = $OfficeId.ToLower()

if ($OfficeId -notmatch '^[a-zA-Z]{2}\d{4}$')
{
    Write-Log "Invalid Office ID: $OfficeId" "ERROR"
    exit 1
}

$server = "$OfficeId-ppfss01"

    $ShareName = if ($Server -match '^(US|CA)') {
	'networktesting$'
    }
    else {
	'networktest$'
    }

$remote = "\\$server\$ShareName"

Write-Log "Using Office ID: $OfficeId"

# -----------------------------
# CHECK SHARE EXISTS
# -----------------------------

if (-not (Test-Path $remote)) {
    Write-Host ""
    Write-Log "Remote path is not accessible or doesn't exist." "ERROR"
    exit
}

# -----------------------------
# TEST WRITE ACCESS
# -----------------------------
$testFile = Join-Path $remote ("_write_test_{0}.tmp" -f ([guid]::NewGuid()))

try {
    New-Item -Path $testFile -ItemType File -ErrorAction Stop | Out-Null
    Remove-Item -Path $testFile -Force -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-Log "No write access to remote path: $remote"  "ERROR"
    exit
}

# -----------------------------
# NETWORK TYPE
# -----------------------------
$connectionType = "Unknown"
$upAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }

if ($upAdapters | Where-Object { $_.Name -match 'wi|wireless' }) {
    $connectionType = "Wireless"
}
elseif ($upAdapters | Where-Object { $_.Name -match 'ethernet' }) {
    $connectionType = "Wired"
}

# -----------------------------
# CHECK LATENCY TO DETERMINE FILE SIZE
# -----------------------------
Write-Log "Checking Latency..."

$avgLatency = Test-Latency -ComputerName $server

$fileSizeBytes = 100000000
if ($null -eq $avgLatency) {
    $fileSizeBytes = 100000000
    $fileSizeGB = 0.1
	$fileSizeNice = "100MB"
}
elseif ($avgLatency -lt 10) {
    $fileSizeBytes = 750000000
    $fileSizeGB = 0.75
	$fileSizeNice = "750MB"
}
elseif ($avgLatency -le 50) {
    $fileSizeBytes = 100000000
    $fileSizeGB = 0.1
	$fileSizeNice = "100MB"
}
else {
    $fileSizeBytes = 50000000
    $fileSizeGB = 0.05
	$fileSizeNice = "50MB"
}

# -----------------------------
$vpnConnected = Get-VPNStatus
$gateway = Get-Gateway
$preferredgateway = Get-PreferredGateway

# -----------------------------
# CREATE TEST FILE
# -----------------------------
# Write-Host $localTestFile $fileSizeBytes
fsutil file createnew $localTestFile $fileSizeBytes | Out-Null

Write-Log "Starting test with $fileSizeNice..."

# -----------------------------
# UPLOAD
# -----------------------------
Write-Log "Uploading..."

$u = robocopy "$localFolder" "$remote" "$testFileName" /R:2 /W:10 /NFL /NDL /NP /NJH

if ($debug) { $u | ForEach-Object { Write-Debug $_ } }

$uSpeed = Parse-Speed $u

Write-Log "Upload MBps: $($uSpeed.MBps)"
Write-Log "Upload Mbitps: $($uSpeed.Mbitps)"

Remove-Item $localTestFile -Force -ErrorAction SilentlyContinue

# -----------------------------
# DOWNLOAD
# -----------------------------
Write-Log "Downloading..."

$d = robocopy $remote $localFolder $testFileName /R:2 /W:10 /NFL /NDL /NP /NJH

if ($debug) { $d | ForEach-Object { Write-Debug $_ } }

$dSpeed = Parse-Speed $d

Write-Log "Download MBps: $($dSpeed.MBps)"
Write-Log "Download Mbitps: $($dSpeed.Mbitps)"

Remove-Item (Join-Path $remote $testFileName) -Force -ErrorAction SilentlyContinue
Remove-Item $localTestFile -Force -ErrorAction SilentlyContinue

# -----------------------------
# SUMMARY
# -----------------------------

$userLocation = "Remote"

if (-not $vpnConnected) {
	$userLocation = [__ComObject].InvokeMember('SiteName', 'GetProperty', $null, (New-Object -ComObject ADSystemInfo), $null)
}

$summary = [pscustomobject]@{
    RunId               = $runId
    Timestamp           = Get-Date
    Office              = $officeId
    Server              = $server
    Computer            = $env:COMPUTERNAME
    UserName            = "$env:USERDOMAIN\$env:USERNAME"
    ConnectionType      = $connectionType
    UserLocation        = $userLocation

    VPNConnected        = $vpnConnected
    VPNGateway          = $gateway
    VPNPrefferedGateway = $preferredgateway

    AvgLatency = if ($null -ne $avgLatency) {
        [Math]::Round([double]$avgLatency, 2)
    } else {
        $null
    }

    UploadMBps = if ($uSpeed.MBps -ne "") {
        [double]$uSpeed.MBps
    } else {
        $null
    }

    UploadMbitsps = if ($uSpeed.Mbitps -ne "") {
        [double]$uSpeed.Mbitps
    } else {
        $null
    }

    DownloadMBps = if ($dSpeed.MBps -ne "") {
        [double]$dSpeed.MBps
    } else {
        $null
    }

    DownloadMbitsps = if ($dSpeed.Mbitps -ne "") {
        [double]$dSpeed.Mbitps
    } else {
        $null
    }
}


# $summary | Export-Csv $localCsvFile -NoTypeInformation

# -----------------------------
# EMAIL VIA OUTLOOK (NO SMTP)
# -----------------------------
try {
    $outlook = New-Object -ComObject Outlook.Application
    $mail = $outlook.CreateItem(0)

    $mail.To = $resultsRecipient
    $mail.Subject = "$emailPrefix $runId"
    $mail.Body = ($summary | ConvertTo-Json -Depth 3)

#    if (Test-Path $localCsvFile) {
#        $mail.Attachments.Add($localCsvFile) | Out-Null
#    }

    $mail.Send()

    Write-Log "Email sent via Outlook"
}
catch {
    Write-Log "Email failed: $($_.Exception.Message)" "ERROR"
}

Write-Log "Complete"

# -----------------------------
# OUTPUT SUMMARY TO LOG
# -----------------------------
Write-Log ""
Write-Log "================ PERFORMANCE SUMMARY ================"

Write-Log ("Office:        {0}" -f $summary.Office)
Write-Log ("Server:        {0}" -f $summary.Server)
Write-Log ("Computer:      {0}" -f $summary.Computer)
Write-Log ("User:          {0}" -f $summary.UserName)
Write-Log ("File Size:     {0} GB" -f $fileSizeGB)

Write-Log ""
Write-Log ("Connection:    {0}" -f $summary.ConnectionType)
Write-Log ("UserLocation:    {0}" -f $summary.UserLocation)
Write-Log ("VPN Connected: {0}" -f $summary.VPNConnected)

Write-Log ""
Write-Log "GP Info"
Write-Log ("  Gateway:   {0}" -f $summary.VPNGateway)
Write-Log ("  Preferred: {0}" -f $summary.VPNPrefferedGateway)

Write-Log ""
Write-Log ("Avg Latency:    {0} ms" -f $summary.AvgLatency)
Write-Log ("Upload Speed:   {0} MB/s" -f $summary.UploadMBps)
Write-Log ("Download Speed: {0} MB/s" -f $summary.DownloadMBps)
Write-Log ""
Write-Log ("Upload Speed:   {0} Mbit/s" -f $summary.UploadMbitsps)
Write-Log ("Download Speed: {0} Mbit/s" -f $summary.DownloadMbitsps)

Write-Log ""
Write-Log ("Run ID:        {0}" -f $summary.RunId)
Write-Log ("Timestamp:     {0}" -f $summary.Timestamp)

Write-Log "===================================================="

# WAIT FOR 10 Seconds or Key Press

$timeout = 10
$sw = [Diagnostics.Stopwatch]::StartNew()

while ($sw.Elapsed.TotalSeconds -lt $timeout) {
    if ([Console]::KeyAvailable) {
        [Console]::ReadKey($true) | Out-Null
        break
    }
    Start-Sleep -Milliseconds 100
}

