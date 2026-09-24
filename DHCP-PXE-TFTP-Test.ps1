#Requires -Version 5.1
# ==============================================================================
#  DHCP-PXE-TFTP-Test.ps1   Version 1.6.0   (2026-09-24)
#
#  1.6.0  Reworded PXE-server and DHCP-option recommendations for the Configuration Manager
#         PXE Responder Service (no WDS role): dropped WDS from service-name references, and
#         options 066/067 are now flagged HIGH as unsupported by the responder, not just redundant.
#  1.5.0  Relay test: if no PXE server answers the relayed broadcast, send it a relay-style
#         DHCPDISCOVER directly to tell a broken relay path from a PXE server problem.
#         Recommendations no longer assume the IP helper is missing. Added -SkipRelayTest.
#  1.4.0  'Recommended actions' section: what to change on the router / DHCP / DP for this subnet.
#         Added -ReportPath (appends one CSV row per run, for comparing offices).
#  1.3.0  When DHCP options 66/67 supply the boot file, also ask next-server on UDP 4011
#         and warn + TFTP-test both if the paths differ
#  1.2.1  Stage 3 header shows when TFTP options are disabled
#  1.2.0  Added -TftpNoOptions (plain RFC 1350 read request)
#  1.1.0  Fixed empty reply list being counted as one offer
#  1.0.0  Initial: DHCP discover + PXE 4011 request + TFTP download
# ==============================================================================
<#
.SYNOPSIS
    Tests the full SCCM / ConfigMgr PXE boot chain from a Windows machine:
      1. DHCP       - broadcasts a PXE-style DHCPDISCOVER and collects every DHCPOFFER / ProxyDHCP offer
      2. PXE        - sends a DHCPREQUEST to UDP 4011 on each PXE server (what a real PXE ROM does)
                      and reads the boot file name and next-server from the DHCPACK
      3. TFTP       - downloads the boot file (plus any extra files) over TFTP and reports
                      size, time, throughput, retransmits and SHA256
      4. Actions    - lists what needs changing (IP helpers, DHCP options 066/067, DP, firewall)
                      for the subnet the script is run on

.DESCRIPTION
    Based on Net-DhcpDiscover.ps1 by Chris Dent, reworked by Andreas Hammarskjold (2Pint Software).
    Extended with PXE port 4011 (BINL) request and a TFTP client (RFC 1350 / 2347 / 2348 / 2349 / 7440).

    Fixes over the original:
      - Replies are filtered on transaction ID, so other clients' DHCP traffic is ignored
      - Option 60 decoded as vendor class and option 67 as boot file name (was decoded as a time span)
      - Duplicate options no longer throw; SName is populated correctly; receive buffer off-by-one fixed
      - MAC may be delimited with '.', '-', ':' or nothing

.PARAMETER MacAddressString
    MAC address to present. For SCCM this must be a known device with a PXE deployment,
    or unknown computer support must be enabled on the DP.

.PARAMETER UUIDString
    SMBIOS GUID to present (option 97).

.PARAMETER ProcessorArchitecture
    Option 93 client architecture: 0 = BIOS x86/x64, 6 = UEFI x86, 7 = UEFI x64, 9 = EFI BC.

.PARAMETER Option60String
    Vendor class. Defaults to PXEClient:Arch:<arch>:UNDI:003000.

.PARAMETER DiscoverTimeout
    Seconds to wait for offers / ACKs. Increase if the DP has a PXE response delay configured.

.PARAMETER PxeServer
    Also send the 4011 request to this server even if it didn't answer the DISCOVER.

.PARAMETER TftpServer
    Override the TFTP server returned by PXE.

.PARAMETER BootFile
    Override the boot file returned by PXE.

.PARAMETER AdditionalTftpFiles
    Extra files to pull from the TFTP server, relative to RemoteInstall,
    e.g. 'SMSImages\PS100004\boot.PS100004.wim' for a realistic throughput test.

.PARAMETER TftpOnly
    Skip DHCP/PXE and only test TFTP (requires -TftpServer and -BootFile).

.PARAMETER TftpBlockSize
    Requested TFTP block size (SCCM default is 4096 on the client side; 1456 avoids fragmentation).

.PARAMETER TftpWindowSize
    Requested TFTP window size (RFC 7440). 1 = classic lock-step TFTP.

.PARAMETER TftpNoOptions
    Send a plain RFC 1350 read request (no blksize/tsize/windowsize) - useful if the server rejects option negotiation.

.PARAMETER OutputPath
    Folder to save downloaded files to. If omitted, files are hashed but not saved.

.PARAMETER ReportPath
    CSV file to append one summary row to per run (e.g. a share), so results from every office can be compared.

.PARAMETER SkipRelayTest
    Don't run the relay test. Normally, if no PXE server answers the relayed broadcast, the script sends
    the PXE server a relay-style DHCPDISCOVER directly (from UDP 67, with this PC as the relay address)
    to tell a broken router relay path apart from a PXE server problem.

.PARAMETER PassThru
    Return a result object as well as printing the report.

.EXAMPLE
    .\DHCP-PXE-TFTP-Test.ps1 -MacAddressString 00-15-5D-01-02-03 -UUIDString 4C4C4544-0042-3510-8052-B4C04F4D4D32

.EXAMPLE
    .\DHCP-PXE-TFTP-Test.ps1 -ProcessorArchitecture 0 -AdditionalTftpFiles 'SMSImages\PS100004\boot.PS100004.wim' -TftpBlockSize 1456 -TftpWindowSize 8

.EXAMPLE
    .\DHCP-PXE-TFTP-Test.ps1 -TftpOnly -TftpServer 10.0.0.20 -BootFile 'smsboot\x64\wdsmgfw.efi' -OutputPath C:\Temp\PXE

.EXAMPLE
    .\DHCP-PXE-TFTP-Test.ps1 -MacAddressString 00-11-22-33-44-55 -UUIDString 4C4C4544-0000-1000-8000-000000000000 -ReportPath \\server\share\PXE-Results.csv

.NOTES
    - Run elevated, from a client on the subnet you want to test (not on the DHCP server or DP itself:
      they already own UDP 67/68/4011).
    - Local firewall must allow inbound UDP 68 and replies from the TFTP server.
    - Sends only DISCOVER (never REQUEST to the DHCP server), so no lease is consumed.
#>

[CmdletBinding()]
Param(
    [String]$MacAddressString = "AA:BB:CC:DD:EE:FF",
    [String]$UUIDString = "AABBCCDD-AABB-AABB-AABB-AABBCCDDEEFF",
    [ValidateRange(0, 65535)][int]$ProcessorArchitecture = 7,
    [String]$Option60String,
    [int]$DiscoverTimeout = 4,
    [String]$PxeServer,
    [String]$TftpServer,
    [String]$BootFile,
    [String[]]$AdditionalTftpFiles,
    [switch]$TftpOnly,
    [ValidateRange(512, 65464)][int]$TftpBlockSize = 1456,
    [ValidateRange(1, 64)][int]$TftpWindowSize = 1,
    [int]$TftpTimeout = 3,
    [int]$TftpRetries = 5,
    [switch]$TftpNoOptions,
    [String]$OutputPath,
    [String]$ReportPath,
    [switch]$SkipRelayTest,
    [switch]$PassThru
)

$ScriptVersion = '1.6.0'
$ErrorActionPreference = 'Stop'
if (-not $Option60String) { $Option60String = "PXEClient:Arch:{0:D5}:UNDI:003000" -f $ProcessorArchitecture }

#region ---------------------------------------------------------------- Helpers

function ConvertTo-MacBytes([string]$Mac) {
    $clean = $Mac -replace '[-:\.\s]', ''
    if ($clean -notmatch '^[0-9A-Fa-f]{12}$') { throw "Invalid MAC address '$Mac'" }
    $bytes = New-Object byte[] 6
    for ($i = 0; $i -lt 6; $i++) { $bytes[$i] = [Convert]::ToByte($clean.Substring($i * 2, 2), 16) }
    , $bytes
}

function Resolve-IPv4([string]$Name) {
    $ip = $null
    if ([Net.IPAddress]::TryParse($Name, [ref]$ip)) { return $ip }
    $a = [Net.Dns]::GetHostAddresses($Name) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
    if (-not $a) { throw "Could not resolve '$Name' to an IPv4 address" }
    $a
}

function Get-LocalIPv4ForTarget([Net.IPAddress]$Target) {
    # Connecting a UDP socket sends nothing, but tells us which local IP routes to the target
    $s = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
    try { $s.Connect($Target, 4011); $s.LocalEndPoint.Address } finally { $s.Close() }
}

function Get-IPString([byte[]]$b, [int]$o) { '{0}.{1}.{2}.{3}' -f $b[$o], $b[$o + 1], $b[$o + 2], $b[$o + 3] }

function Get-AsciiZ([byte[]]$b, [int]$o, [int]$len) {
    ([Text.Encoding]::ASCII.GetString($b, $o, $len)).Split([char]0)[0]
}

function Get-OptString($Opts, [int]$Code) {
    if ($Opts.ContainsKey($Code)) { ([Text.Encoding]::ASCII.GetString($Opts[$Code])).TrimEnd([char]0) } else { $null }
}

function Write-Stage([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
}

#endregion

#region ---------------------------------------------------------------- DHCP / PXE

function New-DhcpPacket {
    param(
        [byte]$MessageType,                              # 1 = DISCOVER, 3 = REQUEST
        [byte[]]$Xid,
        [byte[]]$MacBytes,
        [Guid]$Uuid,
        [int]$Arch,
        [string]$VendorClass,
        [Net.IPAddress]$ClientIP = [Net.IPAddress]::Any,
        [int]$SecondsElapsed = 4,                        # some IP helpers drop requests with secs = 0
        [switch]$Broadcast
    )
    $hdr = New-Object byte[] 236
    $hdr[0] = 1                                          # BOOTREQUEST
    $hdr[1] = 1                                          # Ethernet
    $hdr[2] = 6                                          # HW addr length
    [Array]::Copy($Xid, 0, $hdr, 4, 4)
    $hdr[8] = [byte](($SecondsElapsed -shr 8) -band 0xFF)
    $hdr[9] = [byte]($SecondsElapsed -band 0xFF)
    if ($Broadcast) { $hdr[10] = 0x80 }
    [Array]::Copy($ClientIP.GetAddressBytes(), 0, $hdr, 12, 4)   # ciaddr
    [Array]::Copy($MacBytes, 0, $hdr, 28, 6)

    $p = New-Object System.Collections.Generic.List[byte]
    $p.AddRange($hdr)
    $p.AddRange([byte[]](99, 130, 83, 99))              # magic cookie
    $p.AddRange([byte[]](53, 1, $MessageType))          # message type
    $prl = [byte[]](1, 3, 6, 15, 43, 54, 60, 66, 67, 97, 128, 129, 130, 131, 132, 133, 134, 135)
    $p.Add(55); $p.Add([byte]$prl.Length); $p.AddRange($prl)
    $p.AddRange([byte[]](57, 2, 5, 192))                # max message size 1472
    $vc = [Text.Encoding]::ASCII.GetBytes($VendorClass)
    $p.Add(60); $p.Add([byte]$vc.Length); $p.AddRange($vc)
    $p.AddRange([byte[]](93, 2, [byte](($Arch -shr 8) -band 0xFF), [byte]($Arch -band 0xFF)))
    $p.AddRange([byte[]](94, 3, 1, 3, 0))               # UNDI 3.0
    $p.AddRange([byte[]](97, 17, 0)); $p.AddRange($Uuid.ToByteArray())
    $p.Add(255)
    while ($p.Count -lt 300) { $p.Add(0) }              # BOOTP minimum size
    , $p.ToArray()
}

function Read-DhcpPacket([byte[]]$Packet, [int]$Length) {
    if ($Length -lt 240) { return $null }
    if ($Packet[236] -ne 99 -or $Packet[237] -ne 130 -or $Packet[238] -ne 83 -or $Packet[239] -ne 99) { return $null }

    $opts = @{}
    $i = 240
    while ($i -lt $Length) {
        $code = $Packet[$i]
        if ($code -eq 0) { $i++; continue }
        if ($code -eq 255 -or ($i + 1) -ge $Length) { break }
        $len = $Packet[$i + 1]
        if (($i + 2 + $len) -gt $Length) { break }
        $val = New-Object byte[] $len
        [Array]::Copy($Packet, $i + 2, $val, 0, $len)
        $opts[[int]$code] = $val
        $i += 2 + $len
    }

    $msgTypes = @{ 1 = 'DHCPDISCOVER'; 2 = 'DHCPOFFER'; 3 = 'DHCPREQUEST'; 4 = 'DHCPDECLINE'
                   5 = 'DHCPACK'; 6 = 'DHCPNAK'; 7 = 'DHCPRELEASE'; 8 = 'DHCPINFORM' }

    [pscustomobject]@{
        Op               = [int]$Packet[0]
        XID              = [BitConverter]::ToString($Packet, 4, 4)
        CIAddr           = Get-IPString $Packet 12
        YIAddr           = Get-IPString $Packet 16
        SIAddr           = Get-IPString $Packet 20
        GIAddr           = Get-IPString $Packet 24
        CHAddr           = ([BitConverter]::ToString($Packet, 28, 6)) -replace '-', ':'
        SName            = Get-AsciiZ $Packet 44 64
        File             = Get-AsciiZ $Packet 108 128
        MessageType      = $(if ($opts.ContainsKey(53)) { $msgTypes[[int]$opts[53][0]] } else { 'BOOTP' })
        ServerIdentifier = $(if ($opts.ContainsKey(54) -and $opts[54].Length -eq 4) { Get-IPString $opts[54] 0 } else { $null })
        VendorClass      = Get-OptString $opts 60
        TftpServerName   = Get-OptString $opts 66
        BootFileName     = Get-OptString $opts 67
        IPxeConfigUrl    = Get-OptString $opts 175
        Options          = $opts
    }
}

function New-UdpSocket([int]$Port = 0) {
    $s = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
    $s.EnableBroadcast = $true
    $s.ExclusiveAddressUse = $false
    $s.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::Broadcast, 1)
    $s.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $Port)))
    $s
}

function Receive-DhcpReplies {
    param([Net.Sockets.Socket]$Socket, [byte[]]$Xid, [int]$TimeoutSeconds, [switch]$FirstOnly)
    $xidString = [BitConverter]::ToString($Xid)
    $results = New-Object System.Collections.Generic.List[object]
    $buf = New-Object byte[] 4096
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (-not $Socket.Poll(200000, [Net.Sockets.SelectMode]::SelectRead)) { continue }
        $remote = [Net.EndPoint](New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0))
        try { $n = $Socket.ReceiveFrom($buf, [ref]$remote) } catch [Net.Sockets.SocketException] { continue }
        $pkt = Read-DhcpPacket -Packet $buf -Length $n
        if (-not $pkt -or $pkt.Op -ne 2 -or $pkt.XID -ne $xidString) { continue }   # not a reply to us
        $pkt | Add-Member NoteProperty SourceIP $remote.Address.ToString()
        $pkt | Add-Member NoteProperty ElapsedMs $sw.ElapsedMilliseconds
        $results.Add($pkt)
        if ($FirstOnly) { break }
    }
    $results.ToArray()   # unrolled; callers wrap in @()
}

function Invoke-PxeRequest([Net.Sockets.Socket]$Socket, [Net.IPAddress]$ServerIP) {
    # DHCPREQUEST to UDP 4011, as a PXE ROM does after a ProxyDHCP offer (uses script-level MAC/GUID/arch)
    $localIP = Get-LocalIPv4ForTarget $ServerIP
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $xid2 = New-Object byte[] 4; (New-Object Random).NextBytes($xid2)
        $req = New-DhcpPacket -MessageType 3 -Xid $xid2 -MacBytes $macBytes -Uuid $uuid -Arch $ProcessorArchitecture -VendorClass $Option60String -ClientIP $localIP
        [void]$Socket.SendTo($req, (New-Object Net.IPEndPoint($ServerIP, 4011)))
        $ack = @(Receive-DhcpReplies -Socket $Socket -Xid $xid2 -TimeoutSeconds $DiscoverTimeout -FirstOnly) | Select-Object -First 1
        if ($ack) { return $ack }
    }
    $null
}

function Invoke-RelayDiscover([Net.IPAddress]$ServerIP) {
    # Act like the router's DHCP relay: unicast DISCOVER from UDP 67 with giaddr = this PC, hops = 1.
    # A PXE server replies to giaddr:67, so an answer proves it serves relayed requests from this subnet.
    $localIP = Get-LocalIPv4ForTarget $ServerIP
    try { $rs = New-UdpSocket -Port 67 }
    catch { return [pscustomobject]@{ Ran = $false; Answered = $false; Offer = $null; Note = "could not bind UDP 67 ($($_.Exception.Message))" } }
    try {
        $x = New-Object byte[] 4; (New-Object Random).NextBytes($x)
        $pkt = New-DhcpPacket -MessageType 1 -Xid $x -MacBytes $macBytes -Uuid $uuid -Arch $ProcessorArchitecture -VendorClass $Option60String -Broadcast
        $pkt[3] = 1                                                          # hops
        [Array]::Copy($localIP.GetAddressBytes(), 0, $pkt, 24, 4)           # giaddr
        [void]$rs.SendTo($pkt, (New-Object Net.IPEndPoint($ServerIP, 67)))
        $replies = @(Receive-DhcpReplies -Socket $rs -Xid $x -TimeoutSeconds $DiscoverTimeout)
        $offer = $replies | Where-Object { $_.VendorClass -like 'PXEClient*' } | Select-Object -First 1
        [pscustomobject]@{ Ran = $true; Answered = [bool]$offer; Offer = $offer; Note = "relay address $localIP" }
    }
    finally { $rs.Close() }
}

#endregion

#region ---------------------------------------------------------------- TFTP

function New-TftpAck([int]$Block) { , [byte[]](0, 4, [byte](($Block -shr 8) -band 0xFF), [byte]($Block -band 0xFF)) }

function Invoke-TftpDownload {
    param(
        [string]$Server,
        [string]$FileName,
        [int]$BlockSize = 1456,
        [int]$WindowSize = 1,
        [int]$TimeoutSeconds = 3,
        [int]$Retries = 5,
        [string]$SavePath,
        [switch]$NoOptions
    )

    $r = [ordered]@{
        Server = $Server; File = $FileName; Success = $false; Bytes = [int64]0; ExpectedBytes = $null
        DurationSec = 0; ThroughputMBps = 0; BlockSize = 512; WindowSize = 1; OptionsAccepted = $false
        Timeouts = 0; OutOfOrder = 0; SHA256 = $null; SavedTo = $null; Error = $null
    }

    $enc = [Text.Encoding]::ASCII
    $sock = $null; $fs = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        $serverIP = Resolve-IPv4 $Server
        $sock = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
        $sock.ReceiveBufferSize = 4MB
        $sock.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)))
        if ($SavePath) { $fs = [IO.File]::Create($SavePath) }

        # Read request with option negotiation
        $rrq = New-Object System.Collections.Generic.List[byte]
        $rrq.AddRange([byte[]](0, 1))
        $fields = @($FileName, 'octet')
        if (-not $NoOptions) {
            $fields += @('blksize', "$BlockSize", 'tsize', '0')
            if ($WindowSize -gt 1) { $fields += @('windowsize', "$WindowSize") }
        }
        foreach ($f in $fields) { $rrq.AddRange($enc.GetBytes($f)); $rrq.Add(0) }

        $lastPacket = $rrq.ToArray()
        $lastDest = New-Object Net.IPEndPoint($serverIP, 69)
        [void]$sock.SendTo($lastPacket, $lastDest)

        $serverEP = $null; $blk = 512; $win = 1
        $expected = 1; $inWindow = 0; $retry = 0; $resyncSent = $false; $blocks = 0
        $buf = New-Object byte[] 65536
        $done = $false

        while (-not $done) {
            if (-not $sock.Poll($TimeoutSeconds * 1000000, [Net.Sockets.SelectMode]::SelectRead)) {
                $retry++; $r.Timeouts++
                if ($retry -gt $Retries) {
                    if ($null -eq $serverEP) { throw "No response from $serverIP on UDP 69 (TFTP service down, firewall, or wrong server)" }
                    throw "Transfer stalled after $($r.Bytes) bytes (block $expected) - $Retries retries exhausted"
                }
                [void]$sock.SendTo($lastPacket, $lastDest)
                $inWindow = 0
                continue
            }

            $remote = [Net.EndPoint](New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0))
            $n = $sock.ReceiveFrom($buf, [ref]$remote)
            if ($n -lt 4 -or -not $remote.Address.Equals($serverIP)) { continue }
            if ($null -eq $serverEP) { $serverEP = $remote }                  # server's transfer ID (port)
            elseif ($remote.Port -ne $serverEP.Port) { continue }             # stray duplicate transfer

            $opcode = ([int]$buf[0] -shl 8) -bor $buf[1]

            if ($opcode -eq 5) {
                $code = ([int]$buf[2] -shl 8) -bor $buf[3]
                $msg = if ($n -gt 4) { $enc.GetString($buf, 4, $n - 4).TrimEnd([char]0) } else { '' }
                throw "TFTP error $code from server: $msg"
            }
            elseif ($opcode -eq 6) {
                # OACK - server accepted (some of) our options
                if ($r.Bytes -eq 0) {
                    $parts = $enc.GetString($buf, 2, $n - 2).Split([char]0)
                    for ($k = 0; ($k + 1) -lt $parts.Length; $k += 2) {
                        $name = $parts[$k].ToLower(); $val = $parts[$k + 1]
                        if ($name -eq 'blksize')    { $blk = [int]$val }
                        if ($name -eq 'windowsize') { $win = [int]$val }
                        if ($name -eq 'tsize')      { $r.ExpectedBytes = [int64]$val }
                    }
                    $r.OptionsAccepted = $true
                    $lastPacket = New-TftpAck 0; $lastDest = $serverEP; $retry = 0
                    [void]$sock.SendTo($lastPacket, $lastDest)
                }
            }
            elseif ($opcode -eq 3) {
                $block = ([int]$buf[2] -shl 8) -bor $buf[3]
                if ($block -eq $expected) {
                    $dataLen = $n - 4
                    if ($dataLen -gt 0) {
                        [void]$sha.TransformBlock($buf, 4, $dataLen, $null, 0)
                        if ($fs) { $fs.Write($buf, 4, $dataLen) }
                    }
                    $r.Bytes += $dataLen; $blocks++
                    $retry = 0; $resyncSent = $false; $inWindow++
                    $thisBlock = $expected
                    $expected = ($expected + 1) -band 0xFFFF                  # 16-bit block number rollover

                    if ($dataLen -lt $blk) { $done = $true }
                    if ($done -or $inWindow -ge $win) {
                        $lastPacket = New-TftpAck $thisBlock; $lastDest = $serverEP; $inWindow = 0
                        [void]$sock.SendTo($lastPacket, $lastDest)
                    }
                    if (($blocks % 512) -eq 0 -and $r.ExpectedBytes -gt 0) {
                        Write-Progress -Activity "TFTP $FileName" -Status ("{0:N1} / {1:N1} MB" -f ($r.Bytes / 1MB), ($r.ExpectedBytes / 1MB)) `
                            -PercentComplete ([Math]::Min(100, [int](100 * $r.Bytes / $r.ExpectedBytes)))
                    }
                }
                else {
                    # Lost / out-of-order packet: re-ACK last good block once so the server resends from there
                    $r.OutOfOrder++
                    if (-not $resyncSent) {
                        $lastPacket = New-TftpAck (($expected - 1) -band 0xFFFF); $lastDest = $serverEP
                        [void]$sock.SendTo($lastPacket, $lastDest)
                        $resyncSent = $true; $inWindow = 0
                    }
                }
            }
        }

        $sw.Stop()
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $r.SHA256 = ([BitConverter]::ToString($sha.Hash)) -replace '-', ''
        $r.BlockSize = $blk; $r.WindowSize = $win
        $r.Success = $true
        if ($r.ExpectedBytes -and $r.ExpectedBytes -ne $r.Bytes) {
            $r.Success = $false
            $r.Error = "Size mismatch: server advertised $($r.ExpectedBytes) bytes, received $($r.Bytes)"
        }
        if ($SavePath) { $r.SavedTo = $SavePath }
    }
    catch {
        $sw.Stop()
        $r.Error = $_.Exception.Message
    }
    finally {
        Write-Progress -Activity "TFTP $FileName" -Completed
        if ($fs) { $fs.Close() }
        if ($sock) { $sock.Close() }
        $sha.Dispose()
        if (-not $r.Success -and $SavePath -and (Test-Path $SavePath)) { Remove-Item $SavePath -Force -ErrorAction SilentlyContinue }
    }

    $r.DurationSec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    if ($sw.Elapsed.TotalSeconds -gt 0) { $r.ThroughputMBps = [Math]::Round(($r.Bytes / 1MB) / $sw.Elapsed.TotalSeconds, 2) }
    [pscustomobject]$r
}

#endregion

#region ---------------------------------------------------------------- Main

$summary = New-Object System.Collections.Generic.List[object]
$actions = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Stage, [string]$Result, [string]$Detail) {
    $summary.Add([pscustomobject]@{ Stage = $Stage; Result = $Result; Detail = $Detail })
}

function Add-Action([string]$Priority, [string]$Where, [string]$Fix, [string]$Why) {
    $actions.Add([pscustomobject]@{ Index = $actions.Count; Priority = $Priority; Where = $Where; Fix = $Fix; Why = $Why })
}

function Get-BootFile($Pkt) {
    if ($Pkt.BootFileName) { $Pkt.BootFileName } elseif ($Pkt.File) { $Pkt.File } else { $null }
}

function Test-SamePath([string]$A, [string]$B) {
    ($A -replace '/', '\').TrimStart('\') -eq ($B -replace '/', '\').TrimStart('\')
}

function Get-SubnetInfo($Offer) {
    # Network, prefix and gateway for the subnet this client is on, from the DHCP offer (options 1 and 3)
    if (-not $Offer -or -not $Offer.Options.ContainsKey(1) -or $Offer.Options[1].Length -lt 4) { return $null }
    $ip = [Net.IPAddress]::Parse($Offer.YIAddr).GetAddressBytes()
    $mask = $Offer.Options[1]
    $netBytes = New-Object byte[] 4
    $bits = 0
    for ($i = 0; $i -lt 4; $i++) {
        $netBytes[$i] = $ip[$i] -band $mask[$i]
        $b = [int]$mask[$i]
        while ($b) { $bits += $b -band 1; $b = $b -shr 1 }
    }
    $gw = if ($Offer.Options.ContainsKey(3) -and $Offer.Options[3].Length -ge 4) { Get-IPString $Offer.Options[3] 0 } else { $null }
    [pscustomobject]@{
        Network   = '{0}.{1}.{2}.{3}' -f $netBytes[0], $netBytes[1], $netBytes[2], $netBytes[3]
        Prefix    = $bits
        MaskBytes = [byte[]]$mask[0..3]
        Gateway   = $gw
    }
}

function Test-InSubnet([string]$Ip, $Sub) {
    if (-not $Sub -or -not $Ip) { return $false }
    $a = [Net.IPAddress]::Parse($Ip).GetAddressBytes()
    $n = [Net.IPAddress]::Parse($Sub.Network).GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) { if (($a[$i] -band $Sub.MaskBytes[$i]) -ne $n[$i]) { return $false } }
    $true
}

$runStart = Get-Date
$macBytes = ConvertTo-MacBytes $MacAddressString
$macText = ([BitConverter]::ToString($macBytes)) -replace '-', ':'
$uuid = [Guid]::Parse($UUIDString)

$offers = @(); $leaseOffers = @(); $proxyOffers = @(); $lease = $null; $sub = $null
$dhcpBootFile = $null; $dhcpNext = $null; $hasDhcpPxeOpts = $false; $expectedPxe = $null
$pxeChecks = New-Object System.Collections.Generic.List[object]
$tftpTargets = New-Object System.Collections.Generic.List[object]
$tftpResults = New-Object System.Collections.Generic.List[object]

Write-Host "SCCM PXE boot chain test v$ScriptVersion - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  MAC  : $macText"
Write-Host "  GUID : $uuid"
Write-Host "  Arch : $ProcessorArchitecture  ($Option60String)"

if ($TftpOnly) {
    if (-not $TftpServer -or -not $BootFile) { throw "-TftpOnly requires -TftpServer and -BootFile" }
    Add-Result 'DHCP' 'SKIP' '-TftpOnly'
    Add-Result 'PXE'  'SKIP' '-TftpOnly'
    $tftpTargets.Add([pscustomobject]@{ Server = $TftpServer; File = $BootFile; Kind = 'Manual' })
}
else {
    # ---------------------------------------------------------- Stage 1: DHCP DISCOVER
    Write-Stage "Stage 1 - DHCP DISCOVER (waiting $DiscoverTimeout s for offers)"

    try { $sock = New-UdpSocket -Port 68 }
    catch { throw "Could not bind UDP port 68: $($_.Exception.Message). Run elevated, and not on a DHCP server or the PXE-enabled distribution point itself." }

    try {
        $xid = New-Object byte[] 4; (New-Object Random).NextBytes($xid)
        $discover = New-DhcpPacket -MessageType 1 -Xid $xid -MacBytes $macBytes -Uuid $uuid -Arch $ProcessorArchitecture -VendorClass $Option60String -Broadcast
        [void]$sock.SendTo($discover, (New-Object Net.IPEndPoint([Net.IPAddress]::Broadcast, 67)))
        $offers = @(Receive-DhcpReplies -Socket $sock -Xid $xid -TimeoutSeconds $DiscoverTimeout)

        foreach ($o in $offers) {
            $isPxe = $o.VendorClass -like 'PXEClient*'
            $hasLease = $o.YIAddr -ne '0.0.0.0'
            $role = if ($hasLease -and $isPxe) { 'DHCP+PXE' } elseif ($hasLease) { 'DHCP' } elseif ($isPxe) { 'ProxyDHCP/PXE' } else { 'Other' }
            $o | Add-Member NoteProperty Role $role
            $o | Add-Member NoteProperty IsPxe $isPxe
            $o | Add-Member NoteProperty HasLease $hasLease
            Write-Host ("  [{0,5} ms] {1,-13} from {2,-15} ServerID={3,-15} YourIP={4,-15} NextSrv={5,-15} File='{6}'" -f `
                $o.ElapsedMs, $role, $o.SourceIP, $o.ServerIdentifier, $o.YIAddr, $o.SIAddr, (Get-BootFile $o))
            if ($o.IPxeConfigUrl) { Write-Host "             iPXE / 2Pint config URL: $($o.IPxeConfigUrl)" }
        }

        $leaseOffers = @($offers | Where-Object HasLease)
        $proxyOffers = @($offers | Where-Object IsPxe)
        $lease = $leaseOffers | Select-Object -First 1

        if ($lease) {
            $sub = Get-SubnetInfo $lease
            if ($sub) { Write-Host "  Subnet: $($sub.Network)/$($sub.Prefix)   Gateway: $($sub.Gateway)" }
            $hasDhcpPxeOpts = [bool]($lease.Options.ContainsKey(66) -or $lease.Options.ContainsKey(67) -or $lease.File)
            if ($hasDhcpPxeOpts) {
                $dhcpBootFile = Get-BootFile $lease
                $dhcpNext = if ($lease.TftpServerName) { $lease.TftpServerName } elseif ($lease.SIAddr -ne '0.0.0.0') { $lease.SIAddr } else { $lease.ServerIdentifier }
            }
        }

        if ($leaseOffers.Count -gt 0) {
            Add-Result 'DHCP' 'PASS' ("{0} offer(s): {1}" -f $leaseOffers.Count, (($leaseOffers | ForEach-Object { "$($_.YIAddr) from $($_.ServerIdentifier)" }) -join ', '))
        }
        elseif ($offers.Count -gt 0) {
            Add-Result 'DHCP' 'FAIL' 'Only ProxyDHCP replies - no DHCP server offered an address'
        }
        else {
            Add-Result 'DHCP' 'FAIL' 'No offers received'
        }
        if ($hasDhcpPxeOpts) {
            Add-Result 'DHCP' 'WARN' "DHCP hands out PXE boot options: 066/next-server='$dhcpNext' 067='$dhcpBootFile'"
        }

        # ---------------------------------------------------------- Stage 2: PXE (port 4011)
        Write-Stage "Stage 2 - PXE boot server request (UDP 4011)"

        $pxeTargets = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        $addTarget = {
            param($Ip, $How)
            if ($Ip -and -not $seen.ContainsKey($Ip)) { $seen[$Ip] = $true; $pxeTargets.Add([pscustomobject]@{ Ip = $Ip; How = $How }) }
        }
        if ($PxeServer) {
            try { & $addTarget (Resolve-IPv4 $PxeServer).ToString() '-PxeServer' } catch { Write-Host "  Could not resolve -PxeServer '$PxeServer'" -ForegroundColor Yellow }
        }
        foreach ($o in $proxyOffers) {
            & $addTarget $(if ($o.ServerIdentifier) { $o.ServerIdentifier } else { $o.SourceIP }) 'answered the PXE broadcast'
        }
        if ($hasDhcpPxeOpts -and $dhcpNext) {
            try { & $addTarget (Resolve-IPv4 $dhcpNext).ToString() 'DHCP option 066 / next-server' }
            catch { Write-Host "  Could not resolve next-server '$dhcpNext' from DHCP" -ForegroundColor Yellow }
        }
        if ($pxeTargets.Count -gt 0) { $expectedPxe = $pxeTargets[0].Ip }

        if ($pxeTargets.Count -eq 0) {
            Write-Host "  No PXE server to query: nothing answered the PXE broadcast, DHCP doesn't name one, and -PxeServer wasn't given." -ForegroundColor Yellow
            Add-Result 'PXE' 'FAIL' 'No PXE server found for this subnet'
        }

        foreach ($t in $pxeTargets) {
            # Relay test - only needed when nothing answered the (relayed) broadcast
            $relay = $null
            if ($proxyOffers.Count -eq 0 -and -not $SkipRelayTest) {
                $relay = Invoke-RelayDiscover ([Net.IPAddress]::Parse($t.Ip))
                if (-not $relay.Ran) { Write-Host "  Relay test to $($t.Ip) skipped: $($relay.Note)" -ForegroundColor Yellow }
                elseif ($relay.Answered) { Write-Host ("  [{0,5} ms] {1,-15} relay test: answered a relay-style DISCOVER sent directly ({2})" -f $relay.Offer.ElapsedMs, $t.Ip, $relay.Note) -ForegroundColor Green }
                else { Write-Host ("  {0,-15} relay test: no answer to a relay-style DISCOVER sent directly ({1})" -f $t.Ip, $relay.Note) -ForegroundColor Yellow }
            }

            $ack = Invoke-PxeRequest -Socket $sock -ServerIP ([Net.IPAddress]::Parse($t.Ip))
            $file = $null; $next = $t.Ip
            if ($ack) {
                $file = Get-BootFile $ack
                $next = if ($ack.SIAddr -ne '0.0.0.0') { $ack.SIAddr } elseif ($ack.TftpServerName) { $ack.TftpServerName } else { $t.Ip }
                Write-Host ("  [{0,5} ms] {1,-15} ({2}) -> BootFile='{3}' NextSrv={4}" -f $ack.ElapsedMs, $t.Ip, $t.How, $file, $next)
                $extra = ($ack.Options.Keys | Where-Object { $_ -in 43, 243, 250, 252 } | Sort-Object) -join ','
                if ($extra) { Write-Verbose "  ACK carried vendor/WDS options: $extra" }
            }
            else {
                Write-Host ("  {0,-15} ({1}) -> no reply on UDP 4011" -f $t.Ip, $t.How) -ForegroundColor Yellow
            }
            $pxeChecks.Add([pscustomobject]@{
                Server = $t.Ip; FoundVia = $t.How; Answered = [bool]$ack; BootFile = $file; NextServer = $next; Ack = $ack
                RelayTested = [bool]($relay -and $relay.Ran); RelayAnswered = [bool]($relay -and $relay.Answered)
            })
            if ($relay -and $relay.Ran) {
                if ($relay.Answered) { Add-Result 'PXE' 'WARN' "$($t.Ip) answers relayed DISCOVERs sent directly, but not the broadcast relayed by the router" }
                else { Add-Result 'PXE' 'FAIL' "$($t.Ip) did not answer a relay-style DISCOVER sent directly" }
            }

            if (-not $ack) { Add-Result 'PXE' 'FAIL' "$($t.Ip) did not answer on UDP 4011" }
            elseif (-not $file) { Add-Result 'PXE' 'FAIL' "$($t.Ip) answered but gave no boot file" }
            elseif ($file -match 'abortpxe') {
                Add-Result 'PXE' 'WARN' "$($t.Ip) returned '$file' - no deployment available for this MAC/GUID"
                $tftpTargets.Add([pscustomobject]@{ Server = $next; File = $file; Kind = 'PXE' })
            }
            else {
                Add-Result 'PXE' 'PASS' "$($t.Ip) -> $file (TFTP server $next)"
                $tftpTargets.Add([pscustomobject]@{ Server = $next; File = $file; Kind = 'PXE' })
            }
        }

        # The file a client relying only on DHCP options 066/067 would request
        if ($hasDhcpPxeOpts -and $dhcpBootFile -and $dhcpNext) {
            $dup = $tftpTargets | Where-Object { $_.Server -eq $dhcpNext -and (Test-SamePath $_.File $dhcpBootFile) }
            if (-not $dup) { $tftpTargets.Add([pscustomobject]@{ Server = $dhcpNext; File = $dhcpBootFile; Kind = 'DHCP' }) }
        }
    }
    finally {
        try { $sock.Shutdown('Both') } catch {}
        $sock.Close()
    }
}

$goodPxe = $pxeChecks | Where-Object { $_.Answered -and $_.BootFile -and $_.BootFile -notmatch 'abortpxe' } | Select-Object -First 1

# ---------------------------------------------------------- Stage 3: TFTP
$tftpMode = if ($TftpNoOptions) { 'no options, 512-byte blocks' } else { "blksize $TftpBlockSize, windowsize $TftpWindowSize" }
Write-Stage "Stage 3 - TFTP download ($tftpMode)"

# Manual overrides
if (-not $TftpOnly -and ($TftpServer -or $BootFile)) {
    $baseServer = if ($TftpServer) { $TftpServer } elseif ($tftpTargets.Count) { $tftpTargets[0].Server } else { $null }
    $baseFile   = if ($BootFile) { $BootFile } elseif ($tftpTargets.Count) { $tftpTargets[0].File } else { $null }
    $tftpTargets.Clear()
    if ($baseServer -and $baseFile) { $tftpTargets.Add([pscustomobject]@{ Server = $baseServer; File = $baseFile; Kind = 'Manual' }) }
}
if ($AdditionalTftpFiles) {
    $extraServer = if ($TftpServer) { $TftpServer } elseif ($tftpTargets.Count) { $tftpTargets[0].Server } else { $null }
    if ($extraServer) { foreach ($f in $AdditionalTftpFiles) { $tftpTargets.Add([pscustomobject]@{ Server = $extraServer; File = $f; Kind = 'Additional' }) } }
}

if ($OutputPath -and -not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

if ($tftpTargets.Count -eq 0) {
    Add-Result 'TFTP' 'SKIP' 'No TFTP server / boot file to test (use -TftpServer and -BootFile to force)'
}

$kindText = @{ PXE = 'from PXE server'; DHCP = 'from DHCP option 067'; Manual = 'manual'; Additional = 'additional' }
foreach ($t in $tftpTargets) {
    Write-Host "  Downloading '$($t.File)' from $($t.Server) ($($kindText[$t.Kind])) ..."
    $save = if ($OutputPath) { Join-Path $OutputPath (($t.File -split '[\\/]')[-1]) } else { $null }
    $res = Invoke-TftpDownload -Server $t.Server -FileName $t.File -BlockSize $TftpBlockSize -WindowSize $TftpWindowSize `
        -TimeoutSeconds $TftpTimeout -Retries $TftpRetries -SavePath $save -NoOptions:$TftpNoOptions
    $res | Add-Member NoteProperty Kind $t.Kind
    $tftpResults.Add($res)

    if ($res.Success) {
        Write-Host ("  OK   {0:N0} bytes in {1}s ({2} MB/s)  blksize={3} window={4} options={5} timeouts={6} out-of-order={7}" -f `
            $res.Bytes, $res.DurationSec, $res.ThroughputMBps, $res.BlockSize, $res.WindowSize, $res.OptionsAccepted, $res.Timeouts, $res.OutOfOrder) -ForegroundColor Green
        Write-Host "       SHA256 $($res.SHA256)"
        if ($res.SavedTo) { Write-Host "       Saved to $($res.SavedTo)" }
        $state = if ($res.Timeouts -gt 0 -or $res.OutOfOrder -gt 0) { 'WARN' } else { 'PASS' }
        Add-Result 'TFTP' $state ("{0} ({1}) - {2:N0} bytes, {3} MB/s, {4} timeouts, {5} out-of-order" -f $res.File, $kindText[$t.Kind], $res.Bytes, $res.ThroughputMBps, $res.Timeouts, $res.OutOfOrder)
    }
    else {
        Write-Host "  FAIL $($res.Error)" -ForegroundColor Red
        Add-Result 'TFTP' 'FAIL' "$($res.File) ($($kindText[$t.Kind])) from $($res.Server): $($res.Error)"
    }
}

# ---------------------------------------------------------- Analysis: what needs changing
$subText  = if ($sub) { "$($sub.Network)/$($sub.Prefix)" } else { 'this subnet' }
$gwWhere  = if ($sub -and $sub.Gateway) { "Router $($sub.Gateway) (interface for $subText)" } else { "Router for $subText" }
$dhcpSrv  = if ($lease) { $lease.ServerIdentifier } else { $null }
$dhcpWhere = if ($dhcpSrv) { "DHCP server $dhcpSrv, scope $subText" } else { "DHCP scope for $subText" }
$ipHelperAction = $false

if (-not $TftpOnly) {
    # --- DHCP
    if ($offers.Count -eq 0) {
        Add-Action 'HIGH' "Router for this subnet" `
            "Check the IP helper / DHCP relay on this subnet's router points to the DHCP server, and that the scope exists and is active." `
            "No DHCP server answered. (Also confirm this PC is on the subnet you meant to test and its firewall allows inbound UDP 68.)"
    }
    elseif ($leaseOffers.Count -eq 0) {
        Add-Action 'HIGH' "DHCP scope for this subnet" `
            "Check the scope exists, is active and has free addresses, and that the router's IP helper includes the DHCP server." `
            "A PXE server answered but no DHCP server offered an address."
    }
    if ($leaseOffers.Count -gt 1) {
        $ids = ($leaseOffers | ForEach-Object { $_.ServerIdentifier } | Select-Object -Unique) -join ', '
        Add-Action 'MEDIUM' "DHCP for $subText" `
            "Make sure only the intended DHCP server serves this subnet." `
            "Several DHCP servers offered addresses ($ids) - possibly a rogue DHCP server or a duplicate scope."
    }

    # --- PXE broadcast reachability (DHCP relay / IP helper)
    if ($leaseOffers.Count -gt 0 -and $proxyOffers.Count -eq 0) {
        $pxeIp = if ($goodPxe) { $goodPxe.Server } else { $expectedPxe }
        $chk = $pxeChecks | Where-Object { $_.Server -eq $pxeIp } | Select-Object -First 1
        $gwName = if ($sub -and $sub.Gateway) { $sub.Gateway } else { "the router" }
        $alongside = if ($dhcpSrv) { " as well as the DHCP server ($dhcpSrv)" } else { '' }
        $when = $runStart.ToString('HH:mm:ss')
        if ($pxeIp -and (Test-InSubnet $pxeIp $sub)) {
            Add-Action 'HIGH' "PXE server $pxeIp" `
                "Check the PXE Responder service (SccmPxe) is running on $pxeIp and review SMSPXE.log." `
                "$pxeIp is on this subnet but didn't answer the PXE broadcast."
        }
        elseif ($pxeIp -and $chk -and $chk.RelayAnswered) {
            $ipHelperAction = $true
            Add-Action 'HIGH' $gwWhere `
                "Check the DHCP relay (IP helper) on the interface for $subText forwards to $pxeIp$alongside, and add it if missing. If it's already listed, check that nothing between $gwName and $pxeIp (ACLs, firewalls, the DP's own firewall) blocks UDP 67 in either direction, and that the relay sends to all its servers rather than only the first one that answers." `
                "PXE server $pxeIp answered a relay-style request sent to it directly from this PC, but never answered the broadcast relayed by $gwName. So the PXE server is fine and the relay path from this subnet to it isn't working. (SMSPXE.log on $pxeIp will show no 'Packet from' line for MAC $macText around $when if the relayed request isn't arriving.)"
        }
        elseif ($pxeIp -and $chk -and $chk.RelayTested) {
            $ipHelperAction = $true
            $also = if ($chk.Answered) { ", although it did answer on UDP 4011" } else { '' }
            Add-Action 'HIGH' "PXE server $pxeIp / path from $subText" `
                "Look in SMSPXE.log on $pxeIp around $when for 'Packet from' lines with MAC $macText. If there are none, UDP 67 from $subText isn't reaching ${pxeIp}: check ACLs/firewalls (including the DP's own firewall) and the relay on $gwName. If they're there but no reply was sent, the log says why (e.g. device unknown, no deployment)." `
                "$pxeIp answered neither the broadcast relayed by $gwName nor a relay-style request sent to it directly$also."
        }
        elseif ($pxeIp) {
            $ipHelperAction = $true
            Add-Action 'HIGH' $gwWhere `
                "Make sure the DHCP relay (IP helper) on the interface for $subText forwards to $pxeIp$alongside. If it already does, check SMSPXE.log on $pxeIp around $when for MAC $macText to see whether the relayed request arrives, and check ACLs/firewalls for UDP 67 between $gwName and $pxeIp." `
                "No PXE server answered the broadcast relayed from this subnet. (The relay test was skipped, so it's not known whether the problem is the relay path or the PXE server.)"
        }
        else {
            Add-Action 'HIGH' $gwWhere `
                "Make sure the DHCP relay (IP helper) for $subText forwards to the PXE-enabled distribution point that should serve this office. Rerun with -PxeServer <DP IP> to test that DP directly." `
                "No PXE server answered, and DHCP doesn't point to one."
        }
    }

    # --- DHCP options 060/066/067
    if ($hasDhcpPxeOpts) {
        $mismatch = $goodPxe -and $dhcpBootFile -and -not (Test-SamePath $goodPxe.BootFile $dhcpBootFile)
        $optFail = $tftpResults | Where-Object { $_.Kind -eq 'DHCP' -and -not $_.Success } | Select-Object -First 1
        $fix = "Remove options 066 and 067 (currently 066/next-server='$dhcpNext', 067='$dhcpBootFile'), and option 060 if it's also set on this scope."
        if ($ipHelperAction) { $fix += " Do this only after the PXE server answers PXE requests relayed from this subnet (the item above is fixed), or PXE will stop working here." }
        $why = "Options 060/066/067 aren't supported by the Configuration Manager PXE Responder Service (SccmPxe) - they give every client the same boot file whatever its firmware (BIOS or UEFI), and can override or conflict with the PXE responder's own answer."
        if ($mismatch) { $why += " 067 points to '$dhcpBootFile' but PXE server $($goodPxe.Server) hands out '$($goodPxe.BootFile)'." }
        if ($optFail) { $why += " Downloading the 067 file failed: $($optFail.Error)" }
        Add-Action 'HIGH' $dhcpWhere $fix $why
    }

    # --- PXE server answers
    foreach ($c in ($pxeChecks | Where-Object { -not $_.Answered })) {
        $prio = if ($goodPxe) { 'LOW' } else { 'HIGH' }
        Add-Action $prio "PXE server $($c.Server)" `
            "Check SMSPXE.log on $($c.Server) for MAC $macText. Usual causes: the device is unknown and unknown computer support is off, it has no PXE-enabled deployment, or UDP 4011 is blocked between $subText and $($c.Server)." `
            "It didn't answer the PXE request on UDP 4011 (found via: $($c.FoundVia))."
    }
    foreach ($c in ($pxeChecks | Where-Object { $_.Answered -and $_.BootFile -match 'abortpxe' })) {
        Add-Action 'MEDIUM' "ConfigMgr deployments" `
            "Deploy a task sequence with PXE enabled to a collection containing this device (or All Unknown Computers). Ignore this if the test device deliberately has no deployment." `
            "$($c.Server) returned '$($c.BootFile)' - no deployment is available for MAC $macText / GUID $uuid."
    }
}

# --- TFTP
foreach ($r in $tftpResults) {
    if ($r.Success) {
        if ($r.Timeouts -gt 0 -or $r.OutOfOrder -gt 0) {
            Add-Action 'LOW' "Network path $subText -> $($r.Server)" `
                "Check for packet loss on the path (interface errors, duplex mismatch, congested WAN link). If it persists, lower the TFTP block size in the DP's PXE settings." `
                "TFTP needed $($r.Timeouts) retries and saw $($r.OutOfOrder) out-of-order packets downloading '$($r.File)'."
        }
        continue
    }
    $e = [string]$r.Error
    if ($e -match 'No response') {
        Add-Action 'HIGH' "Firewalls / ACLs between $subText and $($r.Server)" `
            "Allow UDP 69 and the high UDP ports TFTP uses for data from $subText to $($r.Server), and check the PXE service is running on $($r.Server)." `
            "The TFTP server didn't respond at all: $e"
    }
    elseif ($e -match 'stalled|Size mismatch') {
        Add-Action 'MEDIUM' "Network path $subText -> $($r.Server)" `
            "Check for packet loss or MTU problems on the path. Rerun with a smaller -TftpBlockSize (e.g. 1024) to compare, and make sure ACLs allow the high UDP ports for the whole transfer." `
            "The TFTP transfer of '$($r.File)' started but didn't finish: $e"
    }
    elseif ($r.Kind -eq 'DHCP') {
        continue    # covered by the 066/067 action above
    }
    elseif ($r.Kind -eq 'PXE') {
        Add-Action 'HIGH' "PXE server $($r.Server)" `
            "Redistribute the boot image to this DP, check 'Deploy this boot image from the PXE-enabled distribution point' is ticked, restart the PXE service and review SMSPXE.log." `
            "The PXE server can't serve the boot file it handed out ('$($r.File)'): $e"
    }
    else {
        Add-Action 'LOW' "TFTP server $($r.Server)" `
            "Check '$($r.File)' is the right path (relative to RemoteInstall). For SCCM PXE Responder, boot files live under smsboot\<BootImageID>\..." `
            "Requested file couldn't be downloaded: $e"
    }
}

# ---------------------------------------------------------- Summary
Write-Stage "Summary"
$colors = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; SKIP = 'DarkGray' }
foreach ($s in $summary) {
    Write-Host ("  {0,-5} {1,-5} {2}" -f $s.Stage, $s.Result, $s.Detail) -ForegroundColor $colors[$s.Result]
}

# ---------------------------------------------------------- Recommended actions
$gwTitle = if ($sub -and $sub.Gateway) { ", gateway $($sub.Gateway)" } else { '' }
$subTitle = if ($sub) { "subnet $subText" } else { $subText }
Write-Stage "Recommended actions - $subTitle$gwTitle"
$rank = @{ HIGH = 0; MEDIUM = 1; LOW = 2 }
$sortedActions = @($actions | Sort-Object @{ Expression = { $rank[$_.Priority] } }, Index)
if ($sortedActions.Count -eq 0) {
    Write-Host "  No changes needed - PXE, DHCP and TFTP are working correctly for this subnet." -ForegroundColor Green
}
else {
    $prioColors = @{ HIGH = 'Red'; MEDIUM = 'Yellow'; LOW = 'Cyan' }
    $n = 1
    foreach ($a in $sortedActions) {
        Write-Host ("  {0}. [{1}] {2}" -f $n, $a.Priority, $a.Where) -ForegroundColor $prioColors[$a.Priority]
        Write-Host "     Fix: $($a.Fix)"
        Write-Host "     Why: $($a.Why)" -ForegroundColor Gray
        $n++
    }
}
Write-Host ""
Write-Host "  Results apply to the subnet this PC is on. Run it from one PC in each office / VLAN." -ForegroundColor DarkGray

# ---------------------------------------------------------- CSV report
$overall = if ($summary | Where-Object Result -eq 'FAIL') { 'FAIL' } elseif ($summary | Where-Object Result -eq 'WARN') { 'WARN' } else { 'PASS' }
if ($ReportPath) {
    try {
        $row = [pscustomobject]@{
            Timestamp         = Get-Date -Format 's'
            Computer          = $env:COMPUTERNAME
            ScriptVersion     = $ScriptVersion
            Subnet            = $subText
            Gateway           = $(if ($sub) { $sub.Gateway } else { '' })
            DhcpServers       = (($leaseOffers | ForEach-Object { $_.ServerIdentifier } | Select-Object -Unique) -join ' ')
            PxeAnsweredBcast  = ($proxyOffers.Count -gt 0)
            Option066         = $dhcpNext
            Option067         = $dhcpBootFile
            PxeServer         = $(if ($goodPxe) { $goodPxe.Server } else { $expectedPxe })
            PxeBootFile       = $(if ($goodPxe) { $goodPxe.BootFile } else { '' })
            TftpOk            = (($tftpResults | Where-Object Success | ForEach-Object { $_.File }) -join ' ')
            TftpFailed        = (($tftpResults | Where-Object { -not $_.Success } | ForEach-Object { $_.File }) -join ' ')
            Overall           = $overall
            Actions           = (($sortedActions | ForEach-Object { "[$($_.Priority)] $($_.Where): $($_.Fix)" }) -join ' | ')
        }
        $row | Export-Csv -Path $ReportPath -Append -NoTypeInformation -Encoding UTF8
        Write-Host "  Results appended to $ReportPath" -ForegroundColor DarkGray
    }
    catch { Write-Host "  Could not write report to ${ReportPath}: $($_.Exception.Message)" -ForegroundColor Yellow }
}
Write-Host ""

if ($PassThru) {
    [pscustomobject]@{
        Overall     = $overall
        Subnet      = $sub
        Summary     = $summary.ToArray()
        Actions     = $sortedActions
        Offers      = $offers
        PxeChecks   = $pxeChecks.ToArray()
        TftpResults = $tftpResults.ToArray()
    }
}

#endregion
