# DHCP-PXE-TFTP-Test.ps1: recommended actions text

Source: `SCCM/DHCP-PXE-TFTP-Test.ps1` v1.16.0 (2026-10-01), lines 1199-1369. This is a copy for reviewing the wording; the script is the master, so update this file when the text changes.

Text is verbatim. Words starting with `$` are filled in when the script runs (for example `$pxeIp` is the PXE server's IP, `$subText` the subnet, `$gwWhere` is "Router <gateway> (interface for <subnet>)", `$when` the time the test started, `$macText` the test MAC).

Each item prints as:

```
  1. [PRIORITY] Where
     Fix: ...
     Why: ...
```

## DHCP

### 1. No DHCP or PXE server answered at all (line 1209)

- **Priority:** HIGH
- **Where:** Router for this subnet
- **Fix:** Check the IP helper / DHCP relay on this subnet's router points to the DHCP server, and that the scope exists and is active.
- **Why:** No DHCP server answered. (Also confirm this PC is on the subnet you meant to test and its firewall allows inbound UDP 68.)

### 2. A PXE server answered but no DHCP server offered an address (line 1214)

- **Priority:** HIGH
- **Where:** DHCP scope for this subnet
- **Fix:** Check the scope exists, is active and has free addresses, and that the router's IP helper includes the DHCP server.
- **Why:** A PXE server answered but no DHCP server offered an address.

### 3. More than one DHCP server offered an address (line 1220)

- **Priority:** MEDIUM
- **Where:** DHCP for $subText
- **Fix:** Make sure only the intended DHCP server serves this subnet.
- **Why:** Several DHCP servers offered addresses ($ids) - possibly a rogue DHCP server or a duplicate scope.

## PXE broadcast / DHCP relay (IP helper)

### 4. PXE server is on this subnet and answered on UDP 4011, but not the broadcast (line 1233)

- **Priority:** LOW
- **Where:** PXE server $pxeIp
- **Fix:** If a real PXE client on this subnet boots, no action is needed. Otherwise check SMSPXE.log on $pxeIp around $when for 'Packet from' lines with MAC $macText, and that this PC's firewall allows inbound UDP 68 (run the script again with a rule allowing it for powershell.exe).
- **Why:** $pxeIp is on this subnet and answered on UDP 4011, but sent no reply to this script's broadcast DISCOVER. That can be a false alarm: a real PXE ROM sends from IP 0.0.0.0, while this script sends from a PC that already has an address, which the PXE Responder may ignore.

### 5. PXE server is on this subnet and answered nothing (line 1238)

- **Priority:** HIGH
- **Where:** PXE server $pxeIp
- **Fix:** Check the PXE Responder service (SccmPxe) is running on $pxeIp and review SMSPXE.log.
- **Why:** $pxeIp is on this subnet but didn't answer the PXE broadcast or the request on UDP 4011.

### 6. PXE server answered the direct relay-style test but not the relayed broadcast (line 1244)

- **Priority:** HIGH
- **Where:** $gwWhere
- **Fix:** Check the DHCP relay (IP helper) on the interface for $subText forwards to $pxeIp$alongside, and add it if missing. If it's already listed, check that nothing between $gwName and $pxeIp (ACLs, firewalls, the DP's own firewall) blocks UDP 67 in either direction, and that the relay sends to all its servers rather than only the first one that answers.
- **Why:** PXE server $pxeIp answered a relay-style request sent to it directly from this PC, but never answered the broadcast relayed by $gwName. So the PXE server is fine and the relay path from this subnet to it isn't working. (SMSPXE.log on $pxeIp will show no 'Packet from' line for MAC $macText around $when if the relayed request isn't arriving.)

### 7. PXE server answered neither the relayed broadcast nor the direct relay test (line 1251)

- **Priority:** HIGH
- **Where:** PXE server $pxeIp / path from $subText
- **Fix:** Look in SMSPXE.log on $pxeIp around $when for 'Packet from' lines with MAC $macText. If there are none, UDP 67 from $subText isn't reaching ${pxeIp}: check ACLs/firewalls (including the DP's own firewall) and the relay on $gwName. If they're there but no reply was sent, the log says why (e.g. device unknown, no deployment).
- **Why:** $pxeIp answered neither the broadcast relayed by $gwName nor a relay-style request sent to it directly$also.

### 8. No PXE answer to the broadcast, relay test skipped (-SkipRelayTest) (line 1257)

- **Priority:** HIGH
- **Where:** $gwWhere
- **Fix:** Make sure the DHCP relay (IP helper) on the interface for $subText forwards to $pxeIp$alongside. If it already does, check SMSPXE.log on $pxeIp around $when for MAC $macText to see whether the relayed request arrives, and check ACLs/firewalls for UDP 67 between $gwName and $pxeIp.
- **Why:** No PXE server answered the broadcast relayed from this subnet. (The relay test was skipped, so it's not known whether the problem is the relay path or the PXE server.)

### 9. No PXE answer and DHCP doesn't point to a PXE server (line 1262)

- **Priority:** HIGH
- **Where:** $gwWhere
- **Fix:** Make sure the DHCP relay (IP helper) for $subText forwards to the PXE-enabled distribution point that should serve this office. Rerun with -PxeServer <DP IP> to test that DP directly.
- **Why:** No PXE server answered, and DHCP doesn't point to one.

## PXE response delay

### 10. A PXE server answered the broadcast only after 4 s or more (response delay) (line 1271)

- **Priority:** LOW
- **Where:** PXE server $who
- **Fix:** If this isn't deliberate, set the PXE response delay on the distribution point to 0 (distribution point properties, PXE tab). Only use a delay when several PXE servers answer the same subnet and one should win.
- **Why:** $who answered the broadcast only after $([math]::Round($po.ElapsedMs / 1000, 1)) s. A PXE server with a response delay ignores each DISCOVER until the client's elapsed time reaches the delay (SMSPXE.log: 'Response delay is N. Ignoring request.'), so real clients wait that long before PXE starts.

## DHCP options 060/066/067

### 11. Options 060/066/067 are set on the DHCP scope (line 1285)

- **Priority:** HIGH
- **Where:** `$dhcpWhere` = "DHCP server <server>, scope <subnet>" (or "DHCP scope for <subnet>")
- **Fix:** Remove options 066 and 067 (currently 066/next-server='$dhcpNext', 067='$dhcpBootFile'), and option 060 if it's also set on this scope.
  - Added when a relay/IP helper item is also listed: Do this only after the PXE server answers PXE requests relayed from this subnet (the item above is fixed), or PXE will stop working here.
- **Why:** Options 060/066/067 aren't supported by the Configuration Manager PXE Responder Service (SccmPxe) - they give every client the same boot file whatever its firmware (BIOS or UEFI), and can override or conflict with the PXE responder's own answer.
  - Added if 067 differs from the PXE server's boot file: 067 points to '$dhcpBootFile' but PXE server $($goodPxe.Server) hands out '$($goodPxe.BootFile)'.
  - Added if the 067 file download failed: Downloading the 067 file failed: $($optFail.Error)

## PXE server answers

### 12. A PXE server didn't answer on UDP 4011 (LOW if another PXE server worked, else HIGH) (line 1291)

- **Priority:** $prio
- **Where:** PXE server $($c.Server)
- **Fix:** Check SMSPXE.log on $($c.Server) for MAC $macText. Usual causes: the device is unknown and unknown computer support is off, it has no PXE-enabled deployment, or UDP 4011 is blocked between $subText and $($c.Server).
- **Why:** It didn't answer the PXE request on UDP 4011 (found via: $($c.FoundVia)).

### 13. PXE server returned abortpxe (no deployment for this device) (line 1296)

- **Priority:** MEDIUM
- **Where:** ConfigMgr deployments
- **Fix:** Deploy a task sequence with PXE enabled to a collection containing this device (or All Unknown Computers). Ignore this if the test device deliberately has no deployment.
- **Why:** $($c.Server) returned '$($c.BootFile)' - no deployment is available for MAC $macText / GUID $uuid.

## TFTP

### 14. TFTP worked but needed retries or saw out-of-order packets (line 1306)

- **Priority:** LOW
- **Where:** Network path $subText -> $($r.Server)
- **Fix:** Check for packet loss on the path (interface errors, duplex mismatch, congested WAN link). If it persists, lower the TFTP block size in the DP's PXE settings.
- **Why:** TFTP needed $($r.Timeouts) retries and saw $($r.OutOfOrder) out-of-order packets downloading '$($r.File)'.

### 15. TFTP server didn't respond at all (line 1314)

- **Priority:** HIGH
- **Where:** Firewalls / ACLs between $subText and $($r.Server)
- **Fix:** Allow UDP 69 and the high UDP ports TFTP uses for data from $subText to $($r.Server), and check the PXE service is running on $($r.Server).
- **Why:** The TFTP server didn't respond at all: $e

### 16. TFTP transfer started but stalled or the size was wrong (line 1319)

- **Priority:** MEDIUM
- **Where:** Network path $subText -> $($r.Server)
- **Fix:** Check for packet loss or MTU problems on the path. Rerun with a smaller -TftpBlockSize (e.g. 1024) to compare, and make sure ACLs allow the high UDP ports for the whole transfer.
- **Why:** The TFTP transfer of '$($r.File)' started but didn't finish: $e

### 17. PXE server can't serve the boot file it handed out (line 1327)

- **Priority:** HIGH
- **Where:** PXE server $($r.Server)
- **Fix:** Redistribute the boot image to this DP, check 'Deploy this boot image from the PXE-enabled distribution point' is ticked, restart the PXE service and review SMSPXE.log.
- **Why:** The PXE server can't serve the boot file it handed out ('$($r.File)'): $e

### 18. Any other TFTP download failure (line 1332)

- **Priority:** LOW
- **Where:** TFTP server $($r.Server)
- **Fix:** Check '$($r.File)' is the right path (relative to RemoteInstall). For SCCM PXE Responder, boot files live under smsboot\<BootImageID>\...
- **Why:** Requested file couldn't be downloaded: $e

## Other text in this section

- Heading: `Recommended actions - subnet <subnet>, gateway <gateway>`
- Order: HIGH first, then MEDIUM, then LOW; within a priority, in the order above.
- When there are no actions: No changes needed - PXE, DHCP and TFTP are working correctly for this subnet.
- Footer line (always): Results apply to the subnet this PC is on. Run it from one PC in each office / VLAN.
- CSV report `Actions` column: each item as `[PRIORITY] Where: Fix`, joined with ` | ` (the Why is not included).
