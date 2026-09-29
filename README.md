# Scripts

A collection of standalone admin / diagnostic scripts. Each script is self-contained (no shared
modules) — read its own header comment (`Get-Help .\Script.ps1 -Full` for PowerShell) for full
usage, parameters and examples.

| Script | Description |
| --- | --- |
| [`SCCM/DHCP-PXE-TFTP-Test.ps1`](SCCM/DHCP-PXE-TFTP-Test.ps1) | Tests the full SCCM / ConfigMgr PXE boot chain from a Windows client: DHCP discover, PXE boot server request (UDP 4011), TFTP download, and a report of recommended fixes for the subnet it's run from. |

## Adding a new script

- One script per file at the repo root, unless it needs supporting files (helper modules, sample
  data, templates) — in that case give it its own subfolder (`ScriptName/`) containing the script
  plus its supporting files.
- Add a row to the table above.
- Keep a version/changelog header in the script itself (see `DHCP-PXE-TFTP-Test.ps1` for the
  pattern) rather than relying on git history alone — these scripts are often copied and run
  standalone, away from the repo.
