#Requires -Version 5.1
# ==============================================================================
#  Set-TryNextClosestSite.ps1   Version 1.5.0   (2026-11-02)
#  Maintained by Bill Walker (Christchurch)
#
#  1.5.0  First version in this repo (version numbers follow the guide, Imaging/Domain-Join-Closest-DC.pdf).
# ==============================================================================

<#
.SYNOPSIS
    Turns on the Netlogon "Try Next Closest Site" policy in the newly applied
    Windows image, so the task sequence's domain join uses the closest site that
    has a WRITABLE domain controller instead of any DC in the domain.

.DESCRIPTION
    Run this as a "Run PowerShell Script" step in WinPE, AFTER "Apply Operating
    System" and BEFORE "Setup Windows and ConfigMgr".

    Why: a domain join must create the computer account, so it asks for a
    writable DC. If the machine's own AD site only has a read-only DC (RODC), the
    DC locator falls back to a domain-wide DNS lookup and uses whichever writable
    DC answers first, which can be in any country. With TryNextClosestSite = 1 it
    tries the next closest site (by AD site link cost) before giving up on site
    awareness.

    The script loads the offline SOFTWARE hive of the new OS and sets:
        HKLM\SOFTWARE\Policies\Microsoft\Netlogon\Parameters
            TryNextClosestSite  REG_DWORD  1

    This is the same value the Group Policy setting writes:
        Computer Configuration > Administrative Templates > System > Net Logon >
        DC Locator DNS Records > Try Next Closest Site

    Test on one build first: check that netsetup.log on the built machine shows a
    DC in the expected site on its "Domain:" line.

.PARAMETER TargetDrive
    Drive the new OS was applied to, for example C: or D:. If omitted, the script
    reads the task sequence variable OSDTargetSystemDrive.

.EXAMPLE
    Run PowerShell Script step (WinPE), no parameters:
        Set-TryNextClosestSite.ps1

.EXAMPLE
    Testing outside a task sequence, against an image applied to D:
        .\Set-TryNextClosestSite.ps1 -TargetDrive D:
#>

[CmdletBinding()]
param(
    [string]$TargetDrive
)

$ErrorActionPreference = 'Stop'
Write-Output "Set-TryNextClosestSite.ps1 version 1.5.0"

if (-not $TargetDrive) {
    try {
        $ts = New-Object -ComObject Microsoft.SMS.TSEnvironment
        $TargetDrive = $ts.Value('OSDTargetSystemDrive')
    } catch {
        throw "No -TargetDrive given and not running in a task sequence (OSDTargetSystemDrive unavailable)."
    }
}
if (-not $TargetDrive) { throw "OSDTargetSystemDrive is empty. Run this step after Apply Operating System." }

$TargetDrive = $TargetDrive.TrimEnd('\')
$hivePath = Join-Path $TargetDrive 'Windows\System32\config\SOFTWARE'
if (-not (Test-Path $hivePath)) { throw "Offline SOFTWARE hive not found at $hivePath" }

$mount = 'HKLM\TS_OfflineSoftware'
$key   = "$mount\Policies\Microsoft\Netlogon\Parameters"

Write-Output "Loading $hivePath as $mount"
& reg.exe load $mount $hivePath | Out-Null
if ($LASTEXITCODE -ne 0) { throw "reg load failed with exit code $LASTEXITCODE" }

try {
    & reg.exe add $key /v TryNextClosestSite /t REG_DWORD /d 1 /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg add failed with exit code $LASTEXITCODE" }

    $check = & reg.exe query $key /v TryNextClosestSite
    Write-Output ($check | Where-Object { $_ -match 'TryNextClosestSite' })
}
finally {
    # Release any handles PowerShell holds on the hive before unloading it
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 1
    & reg.exe unload $mount | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "reg unload returned $LASTEXITCODE; the hive may still be loaded." }
    else { Write-Output "Unloaded $mount" }
}

Write-Output "TryNextClosestSite = 1 set in the new OS on $TargetDrive"
