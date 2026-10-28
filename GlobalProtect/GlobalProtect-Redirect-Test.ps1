#Requires -Version 5.1
# ==============================================================================
#  GlobalProtect-Redirect-Test.ps1   Version 1.0.0   (2026-10-28)
#  Maintained by Bill Walker (Christchurch)
#
#  1.0.0  Initial: reads a CSV of IP addresses, connects to each over HTTPS and reports whether it redirects
#         to /global-protect/login.esp (a Palo Alto GlobalProtect portal or gateway login page).
# ==============================================================================
<#
.SYNOPSIS
    Tests HTTPS on a list of IP addresses (from a CSV file) and reports which ones redirect to the
    GlobalProtect login page, /global-protect/login.esp.

.DESCRIPTION
    For each address the script requests https://<address>/ and follows any redirects itself (up to -MaxRedirects),
    so every Location header can be checked. A target passes when one of the redirects points to -ExpectedPath
    (default /global-protect/login.esp). A page that answers 200 and sends the browser there with a meta refresh
    or JavaScript also counts, and is shown as a page redirect.

    Certificate errors are ignored, because the certificate is issued for a name, not for the IP address being
    tested. The certificate's subject, expiry date and any errors are still reported. Only the requests this script
    makes ignore certificate errors; nothing is changed for the rest of the PowerShell session.

    Result for each target:
      PASS       Redirects to -ExpectedPath
      WRONG      Answers on HTTPS but redirects somewhere else
      NO-REDIR   Answers on HTTPS but does not redirect
      ERROR      No HTTPS answer (timeout, connection refused, TLS failure, name not resolved)

    The results are written to a CSV file (the input CSV's columns plus the result columns) and everything shown
    on the console is saved to a log file, both in the folder the script is run from unless -OutputCsv / -LogPath
    say otherwise.

.PARAMETER CsvPath
    CSV file listing the addresses to test, one per row. The address column is found by name (IP, IPAddress,
    IP Address, Address, Host, HostName, Target, case does not matter), or set it with -IpColumn; otherwise the
    first column is used. A CSV with no header row (the first row is already an address) also works. An optional
    Port column sets the port for that row. Blank rows and rows starting with # are skipped. Other columns (for
    example a site name) are copied to the results CSV.

.PARAMETER Target
    Addresses to test, typed on the command line instead of (or as well as) -CsvPath. An address can include a
    port, e.g. 192.0.2.10:8443.

.PARAMETER IpColumn
    Name of the CSV column that holds the address, when it is not one of the names -CsvPath looks for.

.PARAMETER Port
    HTTPS port to connect to when the address and the CSV do not give one (default 443).

.PARAMETER Path
    Path requested on each target (default /).

.PARAMETER ExpectedPath
    Redirect path that counts as a pass (default /global-protect/login.esp). Compared case-insensitively, ignoring
    the host name and any query string.

.PARAMETER TimeoutSeconds
    Seconds to wait for each target to answer (default 10).

.PARAMETER MaxRedirects
    Most redirects to follow for each target (default 5).

.PARAMETER NoProxy
    Connect straight to each address, ignoring the proxy set in Windows. Without it the requests use the same proxy
    as the browser, so on a network with a web proxy the result shows what the proxy can reach.

.PARAMETER OutputCsv
    Where to save the results CSV. A folder gets a file named GPResults_<computer>_<yyyyMMdd-HHmmss>.csv; a path
    with a file extension is used as the file (overwritten). Default: the folder the script is run from.

.PARAMETER NoOutputCsv
    Don't write the results CSV.

.PARAMETER LogPath
    Where to save the log of the console output. A folder gets a file named GPLog_<computer>_<yyyyMMdd-HHmmss>.log;
    a path with a file extension is used as the log file (appended to). Default: the folder the script is run from.

.PARAMETER NoLog
    Don't write a log file. If the log cannot be written (for example no write access to the folder), the script
    still runs and shows an error at the end.

.PARAMETER PassThru
    Return the result objects as well as printing the report.

.PARAMETER Help
    List the options and exit.

.EXAMPLE
    .\GlobalProtect-Redirect-Test.ps1 -CsvPath .\firewalls.csv

    firewalls.csv:
        Site,IP
        Office A,192.0.2.10
        Office B,198.51.100.20

.EXAMPLE
    .\GlobalProtect-Redirect-Test.ps1 -CsvPath .\list.csv -IpColumn 'Public IP' -OutputCsv C:\Temp\GP

.EXAMPLE
    .\GlobalProtect-Redirect-Test.ps1 -Target 192.0.2.10, 203.0.113.5:4443

.NOTES
    Maintained by Bill Walker (Christchurch).

    - Run from wherever the users connect from (for example outside the network to test the public addresses),
      because the result depends on the route and the firewall rules between this PC and the target.
    - Sends only HTTPS GET requests for the page; it does not log in.
#>

[CmdletBinding()]
Param(
    [String]$CsvPath,
    [String[]]$Target,
    [String]$IpColumn,
    [ValidateRange(1, 65535)][int]$Port = 443,
    [String]$Path = '/',
    [String]$ExpectedPath = '/global-protect/login.esp',
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 10,
    [ValidateRange(0, 20)][int]$MaxRedirects = 5,
    [switch]$NoProxy,
    [String]$OutputCsv,
    [switch]$NoOutputCsv,
    [String]$LogPath,
    [switch]$NoLog,
    [switch]$PassThru,
    [Alias('h')][switch]$Help
)

$ScriptVersion = '1.0.0'
$ErrorActionPreference = 'Stop'
# Address columns -CsvPath looks for, in order, when -IpColumn is not given
$IpColumnNames = 'IP', 'IPAddress', 'IP Address', 'IP_Address', 'Address', 'Host', 'HostName', 'Host Name', 'Target'

function Show-Usage {
    Write-Host "GlobalProtect-Redirect-Test.ps1 v$ScriptVersion" -ForegroundColor White
    Write-Host "Usage: .\GlobalProtect-Redirect-Test.ps1 -CsvPath <file.csv> [options]"
    Write-Host ""
    $params = @()
    try { $params = @((Get-Help $PSCommandPath -Full -ErrorAction Stop).parameters.parameter) } catch { }
    if (-not $params) {
        Write-Host "Could not read the option list. Run: Get-Help .\GlobalProtect-Redirect-Test.ps1 -Full"
        return
    }
    Write-Host "Options:"
    foreach ($p in $params) {
        $type = if ($p.type.name -eq 'SwitchParameter') { '' } else { " <$($p.type.name)>" }
        Write-Host ("  -{0}{1}" -f $p.name, $type) -ForegroundColor Cyan
        foreach ($d in @($p.description)) {
            foreach ($line in (($d.Text -split "`r?`n") | Where-Object { $_.Trim() })) { Write-Host "      $($line.Trim())" }
        }
    }
    Write-Host ""
    Write-Host "Examples: Get-Help .\GlobalProtect-Redirect-Test.ps1 -Examples     Full help: Get-Help .\GlobalProtect-Redirect-Test.ps1 -Full"
}

if ($Help) { Show-Usage; return }

# ---------------------------------------------------------- Logging
# Everything the script shows on the console is also appended to a log file. Write-Host and Write-Warning are
# wrapped so every call is logged; a log that cannot be written never stops the script, the problem is shown at the end.
$script:LogFile = $null
$script:LogError = $null

function Write-LogLine([string]$Text) {
    if (-not $script:LogFile) { return }
    try { Add-Content -LiteralPath $script:LogFile -Value $Text -Encoding UTF8 -ErrorAction Stop }
    catch { $script:LogError = "Could not write to the log file '$($script:LogFile)': $($_.Exception.Message)"; $script:LogFile = $null }
}

function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Object,
        [object]$Separator,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline
    )
    $sep = if ($PSBoundParameters.ContainsKey('Separator')) { [string]$Separator } else { ' ' }
    Write-LogLine (($Object | ForEach-Object { "$_" }) -join $sep)
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}

function Write-Warning {
    [CmdletBinding()]
    param([Parameter(Position = 0, Mandatory = $true)][AllowEmptyString()][string]$Message)
    Write-LogLine "WARNING: $Message"
    Microsoft.PowerShell.Utility\Write-Warning @PSBoundParameters
}

function Write-LogSummary {
    # Last thing printed: where the log went, or why it could not be written (not logged itself)
    if ($script:LogFile) { Write-Host "  Log saved to $($script:LogFile)" -ForegroundColor DarkGray }
    elseif ($script:LogError) {
        Microsoft.PowerShell.Utility\Write-Host ""
        Microsoft.PowerShell.Utility\Write-Host "  ERROR: $($script:LogError) The output above was not saved to a log file." -ForegroundColor Red
    }
}

function Resolve-OutputFile([string]$Given, [string]$DefaultName) {
    # A folder gets the default file name in it, a path with an extension is the file; default is the current folder
    $f = if (-not $Given) { Join-Path (Get-Location).Path $DefaultName }
         elseif ([IO.Path]::HasExtension($Given)) { $Given }
         else { Join-Path $Given $DefaultName }
    $f = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($f)
    $dir = Split-Path -Path $f -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
    $f
}

$runStamp = '{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
if (-not $NoLog) {
    $logTarget = $null
    try {
        $logTarget = Resolve-OutputFile $LogPath "GPLog_$runStamp.log"
        [IO.File]::AppendAllText($logTarget, '')      # create it now so a permissions problem shows up here
        $script:LogFile = $logTarget
    }
    catch {
        $where = if ($logTarget) { $logTarget } else { 'the current folder' }
        $script:LogError = "Could not create the log file at '$where': $($_.Exception.Message)"
    }
}

# A terminating error is written to the log too, and the log problem (if any) is still reported
trap {
    Write-LogLine ("ERROR: " + $_.Exception.Message)
    Write-LogSummary
    break
}

# Name and version first, before anything else can print
Write-Host "GlobalProtect redirect test v$ScriptVersion - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME" -ForegroundColor White

#region ---------------------------------------------------------------- Helpers

# Certificate check for this script's requests only: accept any certificate (it is issued for a name, not the IP
# being tested) but remember what was presented, so it can be reported.
if (-not ('GpRedirectTestTls' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class GpRedirectTestTls {
    public static X509Certificate2 LastCertificate;
    public static SslPolicyErrors LastErrors;
    public static bool Accept(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        LastCertificate = cert == null ? null : new X509Certificate2(cert);
        LastErrors = errors;
        return true;
    }
    public static readonly RemoteCertificateValidationCallback Callback = Accept;
}
'@
}

# Windows PowerShell 5.1 may only offer TLS 1.0 by default; allow 1.2 (and 1.3 where the OS has it)
try {
    $proto = [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') { $proto = $proto -bor [Net.SecurityProtocolType]::Tls13 }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $proto
} catch { }

function Split-HostPort([string]$Text, [int]$DefaultPort) {
    # '192.0.2.10', '192.0.2.10:8443', 'https://192.0.2.10:8443/', '[2001:db8::1]:443' -> host and port
    $t = $Text.Trim() -replace '^https?://', '' -replace '/.*$', ''
    if ($t -match '^\[(?<h>[^\]]+)\](:(?<p>\d+))?$' -or $t -match '^(?<h>[^:]+)(:(?<p>\d+))?$') {
        $p = if ($Matches['p']) { [int]$Matches['p'] } else { $DefaultPort }
        return [pscustomobject]@{ Host = $Matches['h']; Port = $p }
    }
    [pscustomobject]@{ Host = $t; Port = $DefaultPort }   # bare IPv6 address
}

function Get-HostForUri([string]$HostName) { if ($HostName -match ':') { "[$HostName]" } else { $HostName } }

function Test-ExpectedPath([Uri]$Uri) { $Uri -and $Uri.AbsolutePath.TrimEnd('/') -ieq $ExpectedPath.TrimEnd('/') }

function Invoke-NoRedirectRequest([Uri]$Uri) {
    # One GET, redirects not followed. Returns the status, Location header, page start and certificate.
    [GpRedirectTestTls]::LastCertificate = $null
    [GpRedirectTestTls]::LastErrors = [Net.Security.SslPolicyErrors]::None
    $req = [Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $false
    $req.Timeout = $TimeoutSeconds * 1000
    $req.ReadWriteTimeout = $TimeoutSeconds * 1000
    $req.KeepAlive = $false
    if ($NoProxy) { $req.Proxy = $null }
    $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) GlobalProtect-Redirect-Test/$ScriptVersion"
    $req.ServerCertificateValidationCallback = [GpRedirectTestTls]::Callback
    $resp = $null
    try {
        try { $resp = $req.GetResponse() }
        catch [Net.WebException] {
            # 4xx/5xx (and on some versions 3xx) arrive as an exception that still carries the response
            if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
        }
        $body = ''
        if ([int]$resp.StatusCode -eq 200) {
            # Only the start of the page is needed to spot a meta refresh / JavaScript redirect
            try {
                $reader = New-Object IO.StreamReader($resp.GetResponseStream())
                $buf = New-Object char[] 65536
                $n = $reader.ReadBlock($buf, 0, $buf.Length)
                $body = New-Object string($buf, 0, $n)
            } catch { }
        }
        [pscustomobject]@{
            Status   = [int]$resp.StatusCode
            Location = $resp.Headers['Location']
            Server   = $resp.Headers['Server']
            Body     = $body
            Cert     = [GpRedirectTestTls]::LastCertificate
            CertErr  = [GpRedirectTestTls]::LastErrors
        }
    }
    finally { if ($resp) { $resp.Close() } }
}

function Get-ErrorText($Err) {
    # The innermost message is usually the useful one ('No connection could be made...', 'timed out', ...)
    $e = $Err.Exception
    if ($e -is [Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    $msg = $e.Message
    if ($e -is [Net.WebException]) {
        $inner = $e.InnerException
        while ($inner -and $inner.InnerException) { $inner = $inner.InnerException }
        $status = switch ($e.Status.ToString()) {
            'ConnectFailure'        { 'Could not connect' }
            'Timeout'               { 'Timed out' }
            'NameResolutionFailure' { 'Name not resolved' }
            'TrustFailure'          { 'TLS failure' }
            'SecureChannelFailure'  { 'TLS failure' }
            'UnknownError'          { '' }
            default                 { $_ }
        }
        $text = if ($inner) { $inner.Message } else { $e.Message }
        $msg = if ($status) { "${status}: $text" } else { $text }
    }
    ($msg -replace '\s+', ' ').Trim()
}

function Test-Target([string]$HostName, [int]$TargetPort) {
    $start = [Diagnostics.Stopwatch]::StartNew()
    $chain = New-Object System.Collections.Generic.List[string]
    $first = $null; $last = $null; $result = $null; $how = ''; $err = ''
    try {
        $uri = [Uri]("https://{0}:{1}{2}" -f (Get-HostForUri $HostName), $TargetPort, $Path)
        $visited = @{ $uri.AbsoluteUri = $true }
        for ($hop = 0; $hop -le $MaxRedirects; $hop++) {
            $r = Invoke-NoRedirectRequest $uri
            if (-not $first) { $first = $r }
            $last = $r
            if ($r.Status -ge 300 -and $r.Status -lt 400 -and $r.Location) {
                $next = New-Object Uri($uri, $r.Location)
                if ($visited.ContainsKey($next.AbsoluteUri)) { $chain.Add("$($r.Status) -> $($next.AbsoluteUri) (redirect loop)"); break }
                $chain.Add("$($r.Status) -> $($next.AbsoluteUri)")
                if (Test-ExpectedPath $next) { $result = 'PASS'; $how = "HTTP $($r.Status)"; break }
                if ($next.Scheme -ne 'https' -and $next.Scheme -ne 'http') { break }
                $visited[$next.AbsoluteUri] = $true
                $uri = $next
                continue
            }
            # Not an HTTP redirect: look for a meta refresh or JavaScript sending the browser to the login page
            if ($r.Body -and $r.Body -match [regex]::Escape($ExpectedPath)) {
                $chain.Add("$($r.Status) page refers to $ExpectedPath")
                $result = 'PASS'; $how = 'page redirect'
            }
            break
        }
        if (-not $result) { $result = if ($chain.Count) { 'WRONG' } else { 'NO-REDIR' } }
    }
    catch {
        $result = 'ERROR'
        $err = Get-ErrorText $_
    }
    $start.Stop()

    $cert = if ($first) { $first.Cert } else { $null }
    $certErr = ''
    if ($first -and $first.CertErr -ne 'None') {
        $certErr = (($first.CertErr.ToString() -split ',\s*') | ForEach-Object {
            switch ($_) {
                'RemoteCertificateNameMismatch'     { 'name mismatch' }
                'RemoteCertificateChainErrors'      { 'not trusted' }
                'RemoteCertificateNotAvailable'     { 'no certificate' }
                default                             { $_ }
            } }) -join ', '
    }
    [pscustomobject]@{
        Result          = $result
        Port            = $TargetPort
        HttpStatus      = $(if ($first) { $first.Status } else { '' })
        Redirect        = $(if ($how) { $how } else { '' })
        Location        = $(if ($first -and $first.Location) { $first.Location } else { '' })
        RedirectChain   = ($chain -join ' | ')
        FinalStatus     = $(if ($last) { $last.Status } else { '' })
        Server          = $(if ($first -and $first.Server) { $first.Server } else { '' })
        CertSubject     = $(if ($cert) { $cert.Subject } else { '' })
        CertIssuer      = $(if ($cert) { $cert.Issuer } else { '' })
        CertExpires     = $(if ($cert) { $cert.NotAfter.ToString('yyyy-MM-dd') } else { '' })
        CertErrors      = $certErr
        Error           = $err
        Ms              = [int]$start.ElapsedMilliseconds
    }
}

#endregion

# ---------------------------------------------------------- Read the targets
if (-not $CsvPath -and -not $Target) {
    Write-Host "No addresses given. Use -CsvPath <file.csv> (or -Target <address>, ...). -Help lists the options." -ForegroundColor Yellow
    Write-LogSummary
    return
}

$targets = New-Object System.Collections.Generic.List[object]
$extraColumns = @()
if ($CsvPath) {
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) { throw "CSV file '$CsvPath' not found" }
    $lines = @(Get-Content -LiteralPath $CsvPath | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
    if (-not $lines) { throw "CSV file '$CsvPath' has no rows" }

    # No header row when the first field of the first line is already an address
    $firstField = ($lines[0] -split ',')[0].Trim().Trim('"')
    $ipTest = $null
    $hasHeader = -not ([Net.IPAddress]::TryParse((Split-HostPort $firstField $Port).Host, [ref]$ipTest))
    if ($hasHeader) { $rows = @($lines | ConvertFrom-Csv) }
    else {
        $width = (($lines | ForEach-Object { ($_ -split ',').Count }) | Measure-Object -Maximum).Maximum
        $header = @('IP') + @(for ($i = 2; $i -le $width; $i++) { "Column$i" })
        $rows = @($lines | ConvertFrom-Csv -Header $header)
    }
    $columns = @($rows[0].PSObject.Properties.Name)

    $col = $null
    if ($IpColumn) {
        $col = $columns | Where-Object { $_ -ieq $IpColumn } | Select-Object -First 1
        if (-not $col) { throw "Column '$IpColumn' not found in '$CsvPath'. Columns: $($columns -join ', ')" }
    }
    else {
        foreach ($name in $IpColumnNames) {
            $col = $columns | Where-Object { $_.Trim() -ieq $name } | Select-Object -First 1
            if ($col) { break }
        }
        if (-not $col) { $col = $columns[0] }
    }
    $portCol = $columns | Where-Object { $_.Trim() -ieq 'Port' } | Select-Object -First 1
    $extraColumns = @($columns | Where-Object { $_ -ne $col -and $_ -ne $portCol })

    $where = if ($hasHeader) { "column '$col'" } else { 'first column (no header row)' }
    Write-Host "  Reading $($rows.Count) row(s) from $CsvPath, addresses in the $where" -ForegroundColor DarkGray
    foreach ($row in $rows) {
        $addr = "$($row.$col)".Trim()
        if (-not $addr) { continue }
        $rowPort = $Port
        if ($portCol -and "$($row.$portCol)".Trim() -match '^\d+$') { $rowPort = [int]"$($row.$portCol)".Trim() }
        $hp = Split-HostPort $addr $rowPort
            $label = if ($extraColumns) { "$($row.($extraColumns[0]))".Trim() } else { '' }
        $targets.Add([pscustomobject]@{ Input = $addr; Host = $hp.Host; Port = $hp.Port; Label = $label; Row = $row })
    }
}
# Also accept 'a,b c' in one string (as passed by powershell.exe -File)
foreach ($t in @($Target | ForEach-Object { $_ -split '[,;\s]+' })) {
    if (-not $t) { continue }
    $hp = Split-HostPort $t $Port
    $targets.Add([pscustomobject]@{ Input = $t; Host = $hp.Host; Port = $hp.Port; Label = ''; Row = $null })
}
if ($targets.Count -eq 0) { throw "No addresses found to test" }

# ---------------------------------------------------------- Test each target
Write-Host ""
Write-Host ("  Testing {0} address(es): GET https://<address>{1}, pass = redirect to {2}, timeout {3} s" -f $targets.Count, $Path, $ExpectedPath, $TimeoutSeconds) -ForegroundColor Cyan
Write-Host ""
$colors = @{ PASS = 'Green'; WRONG = 'Yellow'; 'NO-REDIR' = 'Yellow'; ERROR = 'Red' }
$hostWidth = [Math]::Max(15, (($targets | ForEach-Object { "$($_.Host):$($_.Port)".Length }) | Measure-Object -Maximum).Maximum)
$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($t in $targets) {
    $i++
    $r = Test-Target $t.Host $t.Port

    $detail = switch ($r.Result) {
        'PASS'     { "$($r.Redirect) to $ExpectedPath" + $(if ($r.RedirectChain -match '\|') { "  ($($r.RedirectChain))" } else { '' }) }
        'WRONG'    { "redirects elsewhere: $($r.RedirectChain)" }
        'NO-REDIR' { "HTTP $($r.HttpStatus), no redirect" }
        'ERROR'    { $r.Error }
    }
    $lbl = if ($t.Label) { "  ($($t.Label))" } else { '' }
    Write-Host ("  [{0,3}/{1}] {2,-8} {3,-$hostWidth} {4}{5}" -f $i, $targets.Count, $r.Result, "$($t.Host):$($t.Port)", $detail, $lbl) -ForegroundColor $colors[$r.Result]
    if ($r.CertSubject) {
        $ce = if ($r.CertErrors) { "  [$($r.CertErrors)]" } else { '' }
        Write-Host ("  {0,-17}{1,-$hostWidth} cert {2}, expires {3}{4}" -f '', '', $r.CertSubject, $r.CertExpires, $ce) -ForegroundColor DarkGray
    }

    # Results CSV row: the input row's own columns first, then the results
    $out = [ordered]@{ Address = $t.Host }
    if ($t.Row) { foreach ($c in $extraColumns) { $out[$c] = $t.Row.$c } }
    foreach ($p in $r.PSObject.Properties) { $out[$p.Name] = $p.Value }
    $results.Add([pscustomobject]$out)

}

# ---------------------------------------------------------- Summary
Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkCyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor DarkCyan
foreach ($name in 'PASS', 'WRONG', 'NO-REDIR', 'ERROR') {
    $n = @($results | Where-Object Result -eq $name).Count
    $label = switch ($name) {
        'PASS'     { "redirect to $ExpectedPath" }
        'WRONG'    { 'redirect somewhere else' }
        'NO-REDIR' { 'answer on HTTPS without redirecting' }
        'ERROR'    { 'no HTTPS answer' }
    }
    $c = if ($n) { $colors[$name] } else { 'DarkGray' }
    Write-Host ("  {0,-8} {1,4}  {2}" -f $name, $n, $label) -ForegroundColor $c
}
if (@($results | Where-Object Result -ne 'PASS')) {
    Write-Host ""
    Write-Host "  Not redirecting to the login page:" -ForegroundColor Yellow
    for ($k = 0; $k -lt $results.Count; $k++) {
        $r = $results[$k]
        if ($r.Result -eq 'PASS') { continue }
        $lbl = if ($targets[$k].Label) { "  ($($targets[$k].Label))" } else { '' }
        Write-Host ("    {0,-8} {1}:{2}{3}" -f $r.Result, $r.Address, $r.Port, $lbl) -ForegroundColor $colors[$r.Result]
    }
}

# ---------------------------------------------------------- Results CSV
Write-Host ""
if (-not $NoOutputCsv) {
    try {
        $csvFile = Resolve-OutputFile $OutputCsv "GPResults_$runStamp.csv"
        $results | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8
        Write-Host "  Results saved to $csvFile" -ForegroundColor DarkGray
    }
    catch { Write-Host "  Could not write the results CSV: $($_.Exception.Message)" -ForegroundColor Yellow }
}
Write-LogSummary

if ($PassThru) { $results }
