Import-Module ActiveDirectory

$Results = @()

# Create 1KB test file
$LocalSource = Join-Path $env:TEMP "NetworkTest_Source"
$LocalDownload = Join-Path $env:TEMP "NetworkTest_Download"

New-Item $LocalSource -ItemType Directory -Force | Out-Null
New-Item $LocalDownload -ItemType Directory -Force | Out-Null

$TestFile = "NetworkTest_$(Get-Random).dat"
$SourceFile = Join-Path $LocalSource $TestFile

$Bytes = New-Object byte[] 1024
(New-Object System.Random).NextBytes($Bytes)
[System.IO.File]::WriteAllBytes($SourceFile,$Bytes)

$Servers = Get-ADComputer -Filter "Name -like '*PPFSS*'" |
    Sort-Object Name


Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Servers Found: $($Servers.Count)" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Starting tests..."
Write-Host ""
$Counter = 0

foreach ($Server in $Servers)
{
    $Counter++

    Write-Host ""
    Write-Host "[$Counter/$($Servers.Count)] Testing $($Server.Name)..." -ForegroundColor Yellow

    $ShareName = if ($Server.Name -match '^(US|CA)') {
	'networktesting$'
    }
    else {
	'networktest$'
    }

    $SharePath = "\\$($Server.Name)\$ShareName"

    $ShareResult    = "Fail"
    $UploadResult   = "Not Tested"
    $DownloadResult = "Not Tested"
    $DeleteResult   = "Not Tested"

    try
    {
        if (Test-Path $SharePath)
        {
            Write-Host "    Share Found" -ForegroundColor Green

            $ShareResult = "Pass"

            robocopy $LocalSource $SharePath $TestFile /R:1 /W:1 /NJH /NJS /NFL /NDL | Out-Null

            $RemoteFile = Join-Path $SharePath $TestFile

            if (Test-Path $RemoteFile)
            {
                Write-Host "    Upload Passed" -ForegroundColor Green
                $UploadResult = "Pass"

                robocopy $SharePath $LocalDownload $TestFile /R:1 /W:1 /NJH /NJS /NFL /NDL | Out-Null

                $DownloadedFile = Join-Path $LocalDownload $TestFile

                if (Test-Path $DownloadedFile)
                {
                    Write-Host "    Download Passed" -ForegroundColor Green
                    $DownloadResult = "Pass"
                }
                else
                {
                    Write-Host "    Download Failed" -ForegroundColor Red
                }

                Remove-Item $RemoteFile -Force -ErrorAction Stop

                if (-not (Test-Path $RemoteFile))
                {
                    Write-Host "    Delete Passed" -ForegroundColor Green
                    $DeleteResult = "Pass"
                }
                else
                {
                    Write-Host "    Delete Failed" -ForegroundColor Red
                }
            }
            else
            {
                Write-Host "    Upload Failed" -ForegroundColor Red
            }
        }
        else
        {
            Write-Host "    Share Not Found" -ForegroundColor Red
        }
    }
    catch
    {
        Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }

    $Results += [PSCustomObject]@{
        Server      = $Server.Name
        Share       = $ShareResult
        Upload1KB   = $UploadResult
        Download1KB = $DownloadResult
        Delete      = $DeleteResult
    }
}

$Results |
    Sort-Object Server |
    Format-Table -AutoSize

# Optional CSV export
$Results |
    Sort-Object Server |
    Export-Csv "$env:TEMP\PPFSS-NetworkTest.csv" -NoTypeInformation