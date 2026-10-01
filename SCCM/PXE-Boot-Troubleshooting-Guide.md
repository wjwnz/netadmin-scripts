# PXE Boot Troubleshooting Guide (Revised)

## Introduction

Use this guide when a device fails to PXE boot or fails during imaging. It is written for Service Desk (Tier 1) and Desktop Support (Tier 2). Start with the symptom tables, decide whether the problem is one device or a whole site, then work through the steps in order. Where a step needs the DHCP team, network team, SCCM Server Admins or EEA, the guide says so.

- **Scope:** UEFI PXE imaging of Windows 11 through Configuration Manager. BIOS settings are given for Dell systems only. The distribution points use the PXE responder without the WDS role, so Microsoft's WDS-specific steps do not apply.
- **What good looks like:** the device shows "Start PXE over IPv4", then "WDS Boot Manager", then WinPE and the task sequence. If you reach WDS Boot Manager, PXE itself is working. The name "WDS Boot Manager" is normal even without the WDS role.
- **Owner and last review date:** to be added before publishing.

## Who does what

| Role | What they do | Hand over to |
| --- | --- | --- |
| **Service Desk (Tier 1)** | Checks power, cable, port and dock (Steps 1 and 3). Uses the symptom tables to decide one device or a whole site. Collects the ticket details (Step 8). | Desktop Support |
| **Desktop Support (Tier 2)** | Checks BIOS and Secure Boot (Steps 2 and 4), GNDS (Step 5) and USB boot (Step 6). Runs the test script on the imaging VLAN and reads its result (Step 7). Collects `smsts.log` (Step 8). | The team the script result points to (see Step 7), or EEA |
| **Escalation teams** | DHCP team, network team and SCCM Server Admins do the network, DHCP and server checks in Step 7. EEA looks at the device image and task sequence (Step 8). | |

## Where did it stop?

PXE boot runs in stages. Find the last stage that worked, then use the owner shown.

| Stage | What you see | Usual owner | Go to |
| --- | --- | --- | --- |
| 1. Network link and IP address | No link lights, or no IP address for the device in GNDS | Service Desk, then Desktop Support | Steps 3 and 5 |
| 2. DHCP and PXE offers | "Start PXE over IPv4" then times out, `PXE-E51`, PXE-E52 | Desktop Support, then DHCP or network team | Steps 5 and 7 |
| 3. Boot program (`wdsmgfw.efi`) over TFTP | `PXE-E53`, `PXE-E55`, PXE-E32, PXE-E3B, or "No bootable device found" | Desktop Support, then DHCP or SCCM Server Admins | Steps 5 and 7 |
| 4. Boot image download and WinPE start | The boot image loads, then the device restarts or shows an error | Desktop Support, then SCCM Server Admins | Steps 7 and 8 |
| 5. Task sequence list and policy | WinPE starts but no task sequence is offered, or a policy error appears | Desktop Support, then EEA | Step 8 |
| 6. Task sequence runs | An error code in the task sequence | EEA | Step 8 |

## Quick triage: what do you see?

Find the on-screen symptom, then go to the step shown. If more than one device is affected, read "Who owns the problem" first.

| What the screen shows | Likely cause | Go to |
| --- | --- | --- |
| No link lights, "Media test failure" or "Media absent" | Cable, port, dock or adapter | Step 3 |
| "Start PXE over IPv4" then times out, or `PXE-E51` (no DHCP or proxyDHCP offers received) or PXE-E52 (proxyDHCP offers received, no DHCP offers) | No DHCP offer: GNDS registration missing or expired, port not authorised, or a DHCP or network problem | Steps 5 and 3. If other devices also fail, it is site-wide. |
| "No bootable device found" after PXE fails | Check GNDS for an IP address for the device. No IP: registration missing or expired, or wrong BIOS settings. Has an IP: the boot information is wrong or late. Usual causes: DHCP options 066/067 on the scope, or a PXE response delay on the distribution point. | Step 5 (check GNDS first). No IP: Steps 5 and 2. Has an IP: Step 7 (SCCM Server Admins). |
| `PXE-E53` (no boot filename received) or `PXE-E55` (proxyDHCP did not reply on port 4011), or PXE-E77 / PXE-E78 (bad or missing discovery server list, could not locate boot server) | PXE responder not answering: device unknown or no deployment, or a DHCP relay problem | One device: Step 8 (EEA). Several devices: Step 7 (SCCM Server Admins). |
| `PXE-E32` (TFTP open timeout) or `PXE-E3B` (file not found), PXE-E35 (TFTP read timeout), PXE-E36 (error received from TFTP server), PXE-E3F (invalid TFTP packet size) or PXE-T04 (access violation) | TFTP blocked on the network, or boot file not available | Step 7 (SCCM Server Admins and network team) |
| "Operating system loader has no signature" | Secure Boot certificate, old BIOS, or boot image not signed for Secure Boot | Step 4 |
| WDS Boot Manager loads, then the task sequence shows an error code | PXE works. The problem is in the image or task sequence. | Step 8: collect `smsts.log` and the error code |

## Who owns the problem

Decide first whether it is one device or the whole site: try a known-good device on the same port or network, or a second device in the same office.

| Situation | What to do | Who to contact |
| --- | --- | --- |
| **Site-wide:** two or more devices fail, or a known-good device also fails on that network | Do not troubleshoot each device. Log one ticket with the site, subnet or VLAN, the time, the devices tested and the exact error text. Run the test in Step 7 if you can. | **SCCM Server Admins** (Windows Server - Corporate) |
| **Single device:** other devices at the same location PXE boot fine | Work through Steps 2 to 6 (BIOS, cable or dock, Secure Boot, GNDS, USB boot). | Then the **EEA team** (Step 8) |
| **Fails after the boot image loads:** a task sequence error, even on one device | Collect `smsts.log` and the error code (Step 8). | **EEA team** |

If the cause is a network link problem at the site, such as no link or 802.1x not authorising ports, tell the network team as well.

**Exception:** if the error is "No bootable device found" and GNDS shows the device has an IP address, the boot information is wrong or late (DHCP options 066/067 on the scope, or a PXE response delay on the distribution point). Contact the **SCCM Server Admins**, even for a single device (see Step 5).

## Step 1: Verify prerequisites

**Who:** Service Desk.

Confirm these before troubleshooting PXE itself:

- The device's MAC address is added to the GNDS site before it is connected to the network (GNDS 4 networks only). If you use a dock or USB Ethernet adapter with MAC pass-through, register the MAC the device presents (the pass-through MAC), not the adapter's own.
- The device is on a wired connection.
- The network cable, dock or USB Ethernet adapter works.
- The device is connected to power.
- Other devices at the same location can PXE boot. If none can, follow "Who owns the problem" and log a ticket for the SCCM Server Admins.

## Step 2: Check BIOS settings

**Who:** Desktop Support.

These settings are for Dell systems. For other makes, use the equivalent settings from the vendor.

| Setting | Value |
| --- | --- |
| Boot Mode | UEFI |
| PXE Enabled | Yes |
| UEFI Network Stack | Enabled |
| Legacy Option ROMs | Disabled |
| Secure Boot | Enabled (or temporarily disabled for troubleshooting) |
| Thunderbolt boot support | Enabled |
| IPv4 PXE Boot | Enabled |
| MAC Address Pass-Through | Passthrough MAC Address |

If PXE still fails:

1. Reset the BIOS to factory defaults. This can clear a BIOS password, change the TPM or Secure Boot state, and trigger BitLocker recovery on a device that already has Windows, so check first.
2. Reapply the PXE settings above.
3. Save and reboot.

## Step 3: Check the network connection

**Who:** Service Desk.

Confirm the link is up and the lights are flashing.

1. Unplug the network cable for two minutes, then plug it back in.
2. Try another network port.
3. Try another dock or adapter.
4. Test a known-good device on the same port and cable. If it also fails, the problem is the port or network, not the device.

## Step 4: Secure Boot error

**Who:** Desktop Support.

Symptom: "Operating System Loader Has No Signature".

Causes:

- The 2023 Secure Boot CA certificate is missing.
- The BIOS is out of date.
- The boot image is not compatible with Secure Boot.

Resolution:

1. Check the BIOS version against the minimum required, then update the BIOS if it is older.
2. Retry PXE boot.
3. If it still fails, temporarily disable Secure Boot.
4. Confirm Secure Boot is enabled again after imaging.

## Step 5: GNDS issues (GNDS 4 offices)

**Who:** Desktop Support.

Symptom: "No bootable device found". A DHCP timeout or a device stuck at "Start PXE over IPv4" can have the same cause, because an unregistered device gets no network access.

**First, check GNDS for an IP address for the device.**

- **The device has an IP address:** the network and GNDS registration are fine, so the problem is the boot information, not the network. Usual causes: the DHCP scope hands out options 066/067 with a boot file path the distribution point does not have, or the distribution point has a PXE response delay so its correct offer arrives too late. Log a ticket for the SCCM Server Admins (Step 7). Include the device's IP from GNDS, its MAC address and the time of the attempt.
- **The device has no IP address:** work through the checks below.

If the device has no IP address, check:

- The computer account is added to the GNDS site. Follow the knowledge base article "Imaging in Offices with 802.1x Enabled on all Ports" (KB0013474) to add it correctly.
- The expiry time is still valid. Devices get 8 hours to image once added to GNDS.
- The registered MAC is the one the device presents (see the dock and adapter note in Step 1).

## Step 6: Use a USB drive

**Who:** Desktop Support.

Use this when PXE fails but the device, network and GNDS registration are fine. Create a bootable USB by following the knowledge base article "Create Bootable USB". This is the equivalent of PXE booting, not the full offline USB media.

Open question: does the USB boot still need the network and GNDS registration? State the answer here once confirmed.

## Step 7: Run the test script, then network and server checks

Use this step for site-wide failures, or when the device-side steps found nothing.

### 7a. Desktop Support: run the test script

**Run the PXE test script.** From a Windows PC on the same VLAN as the failing device, open PowerShell and run the script (`DHCP-PXE-TFTP-Test.ps1`). Do not run it on the DHCP server or the distribution point itself. It checks DHCP offers, the PXE server on UDP 4011 and a TFTP download of the boot file, and lists recommended actions for the subnet. Outside the imaging VLAN, add `-PxeServer <DP IP>` to test a specific distribution point.

**Using the script on the imaging VLAN**

1. Copy the latest version of the script onto the computer before you start. The computer loses the corporate network on the imaging VLAN, so you cannot fetch it afterwards. The first line of the output shows the version.
2. Add the computer's MAC address to "Imaging Workstations" in GNDS. The entry lasts 8 hours.
3. Ask your DA to stop the "Wired AutoConfig" service on the computer.
4. Disconnect and reconnect the network cable. Turn off Wi-Fi and disconnect any dock or second adapter.
5. Check the computer has an IP address in the imaging VLAN.
6. Run the script without `-PxeServer`. On the imaging VLAN it should find the PXE server from the broadcast, as a real client does.
7. Check the `MAC :` line at the top shows this computer's Ethernet adapter and an imaging VLAN address. A dummy MAC means the script could not find the adapter.
8. Start the "Wired AutoConfig" service again to return the computer to the corporate network.
9. Attach the log file the script saved in the folder you ran it from (`DHCP-PXE-TFTP-Test_<computer>_<date time>.log`) to the ticket.

**Example: a successful test on the imaging VLAN** (key lines only; names, addresses and IDs replaced)

```
SCCM PXE boot chain test v1.14.1 - <date time> on <COMPUTER>
  MAC  : <MAC>  (this PC: 'Ethernet', <imaging VLAN IP>)
  Stage 1 finished after 15.1 s (got a DHCP offer and a PXE offer)
  [  142 ms] DHCP           from <router>  ServerID=<DHCP server>  YourIP=<imaging VLAN IP>
  [13438 ms] ProxyDHCP/PXE  from <router>  ServerID=<PXE server>   YourIP=0.0.0.0
             late reply (13.4 s): this PXE server probably has a PXE response delay configured
  [ 1154 ms] <PXE server>  (answered the PXE broadcast) -> BootFile='smsboot\<package ID>\x64\wdsmgfw.efi'
  OK   1,171,224 bytes in 1.59s  timeouts=0 out-of-order=0
  DHCP  PASS    PXE  PASS    TFTP  PASS
  1. [LOW] PXE server <PXE server>: set the PXE response delay on the distribution point to 0
```

How to read it:

- Stage 1 finished with both a DHCP offer (142 ms) and a ProxyDHCP/PXE offer from the PXE server. The PXE offer arrived late, at 13.4 s. This is expected: the PXE response delay on the distribution point is set to 10 seconds by design.
- Stage 2: the PXE server returned the boot file in 1154 ms.
- Stage 3: TFTP downloaded 1,171,224 bytes with 0 timeouts.
- Summary: DHCP, PXE and TFTP all PASS. The one recommended action is LOW and can be ignored here: it is the PXE response delay, which is set to 10 seconds by design. Setting it to 0 is being tested.
- The script reported no DHCP options 066/067, so this scope is not handing out a boot file. This run was taken after options 066/067 were removed from the scope.

Read its result with care. The script sends its DISCOVER from a PC that already has an IP address, while a real PXE ROM has none, but it resends it at 4, 12 and 28 seconds as a ROM does, so a PXE server with a response delay still answers. If the script gets an answer to its direct test but no PXE offer to the broadcast, the router's IP helper is not forwarding to the PXE server. If it reports that the DHCP scope hands out options 066/067, fix that first, because it is a likely cause of "No bootable devices found". Run it from a PC on the same VLAN as the failing device, because DHCP options are set per scope.

**What to do with the script result**

| What the script reports | What it means | Who to contact |
| --- | --- | --- |
| `DHCP WARN`: DHCP hands out PXE boot options 066/067 | DHCP gives clients a boot file path the distribution point does not have (PXE-E36 or PXE-E3B) | DHCP team: remove options 060, 066 and 067 at server and scope level |
| `PXE WARN`: answers relayed DISCOVERs sent directly, but not the broadcast relayed by the router | The router is not forwarding the PXE broadcast to the PXE server | Network team: add the PXE server as a second IP helper address |
| `DHCP FAIL`: no offers received (PXE-E51) | Nothing answered the DHCP broadcast | Network team (port, VLAN, IP helper) and DHCP team (scope) |
| `PXE FAIL`: did not answer on UDP 4011 (PXE-E55) | The PXE server is not answering requests | SCCM Server Admins |
| `TFTP FAIL` (PXE-E32, E35, E36, E3B or T04) | The boot file cannot be downloaded | SCCM Server Admins, and the network team if there are timeouts |
| `late reply` note, LOW action about the PXE response delay | Expected: the distribution point's delay is set to 10 seconds by design | No action |
| All PASS, but the real device still fails | The problem is on the device or in the task sequence | Desktop Support re-checks BIOS and GNDS, then EEA (Step 8) |

### 7b. Escalation teams: network, DHCP and server checks

These checks are for the DHCP team, network team and SCCM Server Admins. Service Desk and Desktop Support do not need to do them, but should include the script output in the ticket.

**Check the network path:**

- The router's IP helper (DHCP relay) for the subnet has an entry for the DHCP server and a second entry for each PXE-enabled distribution point. Without the second entry, devices get an IP address but no PXE offer.
- UDP 67, 68, 4011 and 69 are not blocked between the subnet and the distribution point, including by the distribution point's own firewall.
- The DHCP scope is active and has free addresses.
- DHCP options 060, 066 and 067 are not set on the scope. The Configuration Manager PXE Responder does not support them, and they can override its answer: a client that takes the boot file from DHCP asks the distribution point for a path it does not have, and ends at "No bootable devices found". Check the options at both the server level and the scope that serves the failing VLAN, including any vendor-class policy for PXEClient (for example, `Get-DhcpServerv4OptionValue -ComputerName <DHCP server> -ScopeId <scope> -All`).

**Check the server:**

- The PXE Responder service (SccmPxe) is running on the distribution point.
- The PXE response delay in the distribution point's properties (PXE tab) is set by design (currently 10 seconds; setting it to 0 is being tested). With a delay, the PXE server ignores a client's early DISCOVERs (SMSPXE.log: "Response delay is 10. Ignoring request."). A PXE ROM waits only about 3 seconds before it uses the boot file from the DHCP offer, so if DHCP options 066/067 are also set, the client can end at "No bootable devices found".
- `SMSPXE.log` on the distribution point. Search for the device's MAC address around the time of the failure. A `Packet from` line means the request arrived, and the lines after it give the reason if no reply was sent (for example, the device is unknown or has no deployment). No line means the request never reached the server.

**Check the deployment and the distribution point settings:**

- The device has a task sequence available for PXE: it is in a collection with a PXE-enabled deployment, or it is a new device covered by the All Unknown Computers deployment (unknown computer support is on for the distribution point). ConfigMgr's PXE server only answers a device that has a deployment available (SMSPXE.log: "no advertisements found" and "Not serviced").
- The boot image is distributed to the distribution point and is set to deploy from the PXE-enabled distribution point.
- If every device suddenly fails, check SMSPXE.log for certificate errors, such as error 800B0101 (a certificate is not within its validity period).
- A distribution point with a self-signed certificate creates files under C:\ProgramData\Microsoft\Crypto\RSA\S-1-5-18 for every PXE request, including test runs and retries. Check the folder size and free disk space. Microsoft's article is for the 2012 product, so confirm it still applies.
- If imaging is slow, test the boot image download speed: run the test script with -AdditionalTftpFiles pointing at the boot image WIM (for example SMSImages\<package ID>\boot.<package ID>.wim).

## Step 8: Escalate to the EEA team

Create an Incident ticket for the EEA team for a single-device failure, or for any failure after the boot image loads. Include:

- What troubleshooting has been done, and the result of each step. Include the test script output if you ran it (Step 7).
- The exact error text and code, and the step it happened at. A photo of the screen is best.
- Device model and serial number, MAC address, and BIOS version.
- Site, VLAN or subnet, switch port, and the time of the failure.
- Whether other devices at the site PXE boot (see "Who owns the problem").
- The setup used: network via dock (give the dock model), via USB dongle, image run via PXE boot, via USB boot, or via full USB.
- The `smsts.log` file, if the task sequence started. Copy it before you reboot, because in Windows PE the `X:` drive is lost on restart. See the knowledge base article "Troubleshooting for Windows 11 Image installation" (KB0010380) for how to get to a command prompt (F8) and copy the file.

**Where to find `smsts.log`**

| When the error happens | Location |
| --- | --- |
| Windows PE, before disk format | `X:\Windows\Temp\SMSTSLog\smsts.log` |
| Windows PE, after disk format | `X:\SMSTSLog\smsts.log`, copied to `C:\_SMSTaskSequence\Logs\SMSTSLog\smsts.log` |
| Full Windows, before the agent installs | `C:\_SMSTaskSequence\Logs\SMSTSLog\smsts.log` |
| Full Windows, after the agent installs | `C:\Windows\CCM\Logs\SMSTSLog\smsts.log` |
| After the task sequence finishes | `C:\Windows\CCM\Logs\smsts.log` |

The drive letter may not be `C:` if the device has more than one partition or disk. Use the largest local drive.

Attach logs to the ticket only. They can contain computer and server names, so do not email them or post them in shared channels.
