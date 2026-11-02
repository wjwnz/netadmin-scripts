# Scripts

A collection of standalone admin / diagnostic scripts. Each script is self-contained (no shared
modules) — read its own header comment (`Get-Help .\Script.ps1 -Full` for PowerShell) for full
usage, parameters and examples.

| Script | Description |
| --- | --- |
| [`SCCM/DHCP-PXE-TFTP-Test.ps1`](SCCM/DHCP-PXE-TFTP-Test.ps1) | Tests the full SCCM / ConfigMgr PXE boot chain from a Windows client: DHCP discover, PXE boot server request (UDP 4011), TFTP download, and a report of recommended fixes for the subnet it's run from. |
| [`SCCM/PXE-Boot-Troubleshooting-Guide.md`](SCCM/PXE-Boot-Troubleshooting-Guide.md) | Step-by-step guide for PXE boot and imaging failures: symptom and PXE error-code triage, who to contact for site-wide vs single-device failures, and what to collect for escalation. (A guide, not a script.) |
| [`Imaging/Domain-Join-Closest-DC.pdf`](Imaging/Domain-Join-Closest-DC.pdf) | Guide: why bare metal SCCM builds at a branch whose site only has a read-only DC join through a random writable DC anywhere in the domain, how to confirm it with `nltest`, and the two fixes below. (A guide, not a script.) |
| [`Imaging/Set-TryNextClosestSite.ps1`](Imaging/Set-TryNextClosestSite.ps1) | Task sequence step (WinPE, after Apply Operating System): turns on the Netlogon "Try Next Closest Site" policy in the new OS so the built-in domain join uses the nearest site with a writable DC. Recommended fix. |
| [`Imaging/Join-DomainClosestDC.ps1`](Imaging/Join-DomainClosestDC.ps1) | Task sequence step (full OS, after Setup Windows and ConfigMgr): joins the domain against a named writable DC chosen from the machine's IPv4 address, with the join password read from a hidden task sequence variable. Fallback fix. |
| [`GlobalProtect/GlobalProtect-Redirect-Test.ps1`](GlobalProtect/GlobalProtect-Redirect-Test.ps1) | Reads a CSV of IP addresses, connects to each over HTTPS (certificate errors ignored) and reports which ones redirect to the GlobalProtect login page `/global-protect/login.esp`. Saves a results CSV and a log. [`Example-Targets.csv`](GlobalProtect/Example-Targets.csv) shows the input format. |

## Adding a new script

- One script per file at the repo root, unless it needs supporting files (helper modules, sample
  data, templates) — in that case give it its own subfolder (`ScriptName/`) containing the script
  plus its supporting files.
- Add a row to the table above.
- Keep a version/changelog header in the script itself (see `DHCP-PXE-TFTP-Test.ps1` for the
  pattern) rather than relying on git history alone — these scripts are often copied and run
  standalone, away from the repo.
