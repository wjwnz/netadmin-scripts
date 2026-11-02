#Requires -Version 5.1
# ==============================================================================
#  Join-DomainClosestDC.ps1   Version 1.5.0   (2026-11-02)
#  Maintained by Bill Walker (Christchurch)
#
#  1.5.0  First version in this repo (version numbers follow the guide, Imaging/Domain-Join-Closest-DC.pdf).
#         Fallback for when "Try Next Closest Site" can't be used: joins the domain against a
#         named writable DC chosen from the machine's IPv4 address.
# ==============================================================================

<#
.SYNOPSIS
    Joins the computer to the domain using a specific writable domain controller,
    chosen from the machine's IPv4 address, without the join password ever
    appearing in plain text.

.DESCRIPTION
    FALLBACK method. The recommended fix is Set-TryNextClosestSite.ps1 with the
    built-in Apply Network Settings join. Use this script when that isn't
    possible, or when builds must always use one particular DC.

    Run as a "Run PowerShell Script" step in the FULL OS, after "Setup Windows and
    ConfigMgr", followed by a "Restart Computer" step. Set "Apply Network
    Settings" to "Join a workgroup" so Windows Setup doesn't join first.

    Credentials come from task sequence variables, never from parameters:
        DJUser      DOMAIN\account with rights to create computer objects in the OU
        DJPassword  its password. Create it as a collection variable with
                    "Do not display this value in the Configuration Manager console"
                    ticked (for bare metal builds: on All Unknown Computers, or the
                    collection the task sequence is deployed to).

    The DC is passed to Add-Computer as "domain\dc", the same form Windows Setup
    uses, so the join connects straight to that DC with no DC locator lookup.
    Prefer a writable DC in a site close to the client; read-only DCs (RODCs)
    can't create the computer account.

    EDIT THE CONFIGURATION BLOCK BELOW before use.

.EXAMPLE
    Run PowerShell Script step (full OS), execution policy Bypass, no parameters:
        Join-DomainClosestDC.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Write-Output "Join-DomainClosestDC.ps1 version 1.5.0"

# ---------------------------- CONFIGURATION ----------------------------------
$DomainName = 'corp.example.com'
$OUPath     = 'OU=Laptops,OU=Branch,DC=corp,DC=example,DC=com'

# Writable DC to use for each client IPv4 prefix (first match wins).
# End each prefix with a dot so '10.1.' doesn't also match '10.10.'.
$SiteDCs = [ordered]@{
    '10.1.' = 'HUB-DC01.corp.example.com'   # branch subnet  -> nearest hub with a writable DC
    '10.2.' = 'HUB-DC02.corp.example.com'
}

# Used when no prefix matches. Deliberately no DC locator lookup here: that lookup
# is what picks a random writable DC when the local site only has an RODC.
$DefaultDC  = 'HUB-DC01.corp.example.com'
# -----------------------------------------------------------------------------

$ip = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway |
       Select-Object -First 1).IPv4Address.IPAddress
if (-not $ip) { throw "No IPv4 address with a default gateway found." }

$dc = $SiteDCs.Keys | Where-Object { $ip.StartsWith($_) } |
      ForEach-Object { $SiteDCs[$_] } | Select-Object -First 1
if (-not $dc) { $dc = $DefaultDC }

Write-Output "Client IP $ip -> joining $DomainName using DC $dc"

$ts = New-Object -ComObject Microsoft.SMS.TSEnvironment
$user = $ts.Value('DJUser')
$rawPass = $ts.Value('DJPassword')
if (-not $user -or -not $rawPass) { throw "Task sequence variables DJUser and/or DJPassword are not set." }

$pass = ConvertTo-SecureString $rawPass -AsPlainText -Force
Remove-Variable rawPass
$cred = New-Object System.Management.Automation.PSCredential($user, $pass)

Add-Computer -DomainName $DomainName `
             -Server "$DomainName\$dc" `
             -OUPath $OUPath `
             -Credential $cred -Force -ErrorAction Stop

Write-Output "Join succeeded. Restart the computer with a task sequence Restart Computer step."
Write-Output "Check C:\Windows\debug\netsetup.log: the 'Domain:' line should show $DomainName\$dc."
