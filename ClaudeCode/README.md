# Claude Code add-ons

Two scripts that set up (and trim back) a set of Claude Code plugins, skills and MCP servers on an
Ubuntu/Debian machine.

| Script | What it does |
| --- | --- |
| [`install-claude-addons.sh`](install-claude-addons.sh) | Installs the add-ons. `PROFILE=web` (default) or `PROFILE=full`. |
| [`remove-claude-addons.sh`](remove-claude-addons.sh) | Trims a `full` machine back to `web`. |

## Which profile?

**`web` (default): use on any machine that also runs public-facing services.**
It holds no sign-ins to outside accounts apart from Vercel and Figma. It includes:

- **Build & test:** Superpowers, gstack, graphify, GitHub CLI, Vercel, Playwright (headless), Codex (second reviewer), Claude HUD.
- **Design:** Figma, ui-ux-pro-max, impeccable, taste-skill, emil-design-eng, HyperFrames, Remotion, find-skills.

**`full`: a workstation or a throwaway test VM only.** It adds everything above plus:

- **Research:** Perplexity, Firecrawl, Apify, last30days, Gemini video analysis, humanizer.
- **Social and media:** Metricool, Higgsfield, GPT Image, Nano Banana, ElevenLabs.
- **Office:** Gmail/Calendar/Drive, Granola, Notion, Slack, Zapier.
- **Other:** caveman, Whisper, Ollama.

Several of these run code automatically in every Claude session, and many hold sign-ins to your
accounts. If a machine running them is compromised, all of that goes with it, so don't put
`full` on a server that faces the internet.

Paid or key-based add-ons in `full`:

- **API keys:** Perplexity, GPT Image and Nano Banana need one. Gmail/Calendar/Drive needs a Google Cloud OAuth desktop client. Put these in `~/.config/claude-addons.env` (see the script header). Anything without its key is skipped and listed at the end.
- **Paid plans or credits:** Higgsfield needs a paid plan. Apify, ElevenLabs and Firecrawl use credits.
- **Workspace approval:** a Slack workspace admin has to approve the Slack MCP app.

`SKIP_HEAVY=1` leaves out Ollama and Whisper, which are several GB each and slow without a GPU.

## Running it from a Windows PC

From **PowerShell** (not cmd), with the script in your Downloads folder:

```powershell
scp $env:USERPROFILE\Downloads\install-claude-addons.sh <user>@<host>:~/
ssh -t <user>@<host> "bash ~/install-claude-addons.sh"
# or: ssh -t <user>@<host> "PROFILE=full SKIP_HEAVY=1 bash ~/install-claude-addons.sh"
```

- PowerShell uses `$env:USERPROFILE`. `%USERPROFILE%` only works in cmd, and in PowerShell
  `scp` fails with "No such file or directory".
- Give the Linux username (`<user>@<host>`) if it's different from your Windows one. Otherwise SSH logs in
  as the Windows name and asks for a password that doesn't exist.
- `-t` is needed so the sudo password prompt reaches you.

Run it as your normal user, not root. Both scripts are safe to re-run, and each ends with a
summary of what installed, what was skipped and what's left to do by hand.

## After installing

Inside `claude`, the first time you need each one:

- `/claude-hud:setup` turns on the status bar.
- `codex login` (in the shell), then `/codex:setup`.
- `vercel login` (in the shell).
- `/mcp`, then **Authenticate** on each HTTP server (Figma, Notion, Zapier, ...). Over SSH, open
  the sign-in link it shows in a browser on your PC.

Skills (gstack, graphify, impeccable, emil-design-eng, Remotion, find-skills) don't show up in
`claude plugin list`. They live in `~/.claude/skills/`.

## Troubleshooting

**`apt update` fails with "changed its 'Label' value" (for example `ondrej/php` → "PPA for PHP (deprecated)").**
apt won't update until the change is accepted, and that also blocks the Node install. Fix:
`sudo apt-get update --allow-releaseinfo-change`. Version 1.1.0 of the script does this itself.
Separately, check whether your sites still rely on PHP from that PPA.

**`npx: command not found`, or Playwright shows `ENOENT: Executable not found in $PATH: "npx"`.**
Ubuntu's own `nodejs` package is old (18.x) and comes without npm. Install Node 22 from NodeSource:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs        # replaces Ubuntu's nodejs; the dependency warning is normal
node -v && which npx                  # v22.x and /usr/bin/npx
```

Use this rather than `sudo apt install npm`, which drags in the old Node. Then check Playwright
with `claude mcp get playwright` (it should say Connected).

**`claude mcp add ... -- "$(which npx)" ...` gives "Missing a command after the server name".**
`which npx` came back empty, so Node isn't installed (see above).

**Pasted several commands at once and only the first ran.**
A long-running command such as `apt-get update` or anything waiting on sudo swallows the lines pasted after it. Paste
them one at a time.

**`userdel: group ollama not removed because it has other members`** (remove script).
This is harmless. The `groupdel` straight after it removes the group anyway.

**HyperFrames: "The packages it lists were not installed ..."**
Its skills still work. Only its video rendering needs those packages.
