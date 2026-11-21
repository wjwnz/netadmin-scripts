#!/usr/bin/env bash
# ==============================================================================
#  install-claude-addons.sh   Version 1.1.0   (2026-11-21)
#  Maintained by Bill Walker (Christchurch)
#
#  Installs a set of Claude Code plugins, skills and MCP servers on an Ubuntu/Debian
#  machine. Two profiles:
#    web  (default) - build, test and design tools for website work. Holds no sign-ins
#                     to outside accounts apart from Vercel and Figma. Use this on any
#                     machine that also runs public-facing services.
#    full           - web + research, social, office and media connectors (Notion, Slack,
#                     Zapier, Gmail/Calendar/Drive, ElevenLabs, ...), caveman, Whisper and
#                     Ollama. Use on a workstation or a throwaway test VM.
#
#  Usage (as your normal user, not root):
#    bash install-claude-addons.sh              # web profile
#    PROFILE=full bash install-claude-addons.sh
#    PROFILE=full SKIP_HEAVY=1 bash ...         # full, minus Ollama and Whisper (multi-GB)
#  Over SSH use 'ssh -t' so the sudo password prompt reaches you.
#  Safe to re-run: anything already installed is reported and left alone.
#
#  API keys (full profile only) are read from ~/.config/claude-addons.env (chmod 600):
#    OPENAI_API_KEY=...  GEMINI_API_KEY=...  PERPLEXITY_API_KEY=...
#    GOOGLE_OAUTH_CLIENT_ID=...  GOOGLE_OAUTH_CLIENT_SECRET=...   (Google Cloud desktop OAuth client)
#  Add-ons whose key is missing are skipped and listed at the end.
#
#  1.1.0 Added PROFILE (web default, full). 'apt-get update --allow-releaseinfo-change' so a
#        PPA that relabels itself (e.g. ondrej/php "(deprecated)") no longer blocks apt and,
#        with it, the Node install. Node check now also requires npx (Ubuntu's own nodejs
#        package ships without npm). Stops early if Node 20+ with npx is still missing.
#  1.0.0 First version: every add-on from the "AI office" list, one profile.
# ==============================================================================

set -uo pipefail
PROFILE="${PROFILE:-web}"
case "$PROFILE" in web|full) ;; *) echo "PROFILE must be 'web' or 'full'"; exit 1;; esac

ENV_FILE="$HOME/.config/claude-addons.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a

# Plugin installs can fail with EXDEV when /tmp is tmpfs: use a home-dir temp.
mkdir -p "$HOME/.cache/tmp"; export TMPDIR="$HOME/.cache/tmp"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

OK=(); FAILED=(); SKIPPED=(); TODO=()
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
run()  { local label="$1"; shift; if "$@"; then OK+=("$label"); else FAILED+=("$label"); fi; }
need_key() { if [ -z "${!1:-}" ]; then SKIPPED+=("$2 (needs $1)"); return 1; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

plugin() { # plugin <marketplace-repo-or-""> <plugin@marketplace> <label>
  [ -n "$1" ] && claude plugin marketplace add "$1" >/dev/null 2>&1
  run "$3" claude plugin install "$2"
}
mcp_http() { # mcp_http <name> <url> <label>   (OAuth sign-in later via /mcp)
  if claude mcp get "$1" >/dev/null 2>&1; then OK+=("$3 (already added)"); return; fi
  run "$3" claude mcp add --transport http --scope user "$1" "$2"
  TODO+=("Sign in to $3: run /mcp in claude -> $1 -> Authenticate")
}
mcp_cmd() { # mcp_cmd <name> <label> [-e K=V ...] -- cmd args...
  local name="$1" label="$2"; shift 2
  if claude mcp get "$name" >/dev/null 2>&1; then OK+=("$label (already added)"); return; fi
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  run "$label" claude mcp add --scope user "${envs[@]}" "$name" -- "$@"
}
skill() { local label="$1"; shift; run "$label" npx -y skills add "$@" -g -a claude-code -y; }

# ---------- 0. prerequisites ----------
log "Prerequisites (profile: $PROFILE)"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }
have claude || { echo "Claude Code ('claude') not found on PATH. Install it first."; exit 1; }
have apt-get || { echo "This script needs apt (Ubuntu/Debian)."; exit 1; }

sudo apt-get update -qq --allow-releaseinfo-change || FAILED+=("apt-get update")
sudo apt-get install -y -qq git curl unzip ffmpeg python3 python3-pip pipx zstd gh >/dev/null \
  && OK+=("git, curl, ffmpeg, python3, pipx, GitHub CLI") || FAILED+=("apt packages")

node_ok() {
  local major; major=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
  [ -n "$major" ] && [ "$major" -ge 20 ] && have npx
}
if ! node_ok; then
  log "Installing Node.js 22 LTS (NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null \
    && sudo apt-get install -y -qq nodejs >/dev/null
fi
node_ok || { echo "Node 20+ with npx is still missing - fix that first (see output above)."; exit 1; }
OK+=("Node.js $(node -v)")
have uv  || { curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null && OK+=("uv"); }
have bun || { curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 && OK+=("Bun"); }
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

# ---------- 1. BUILD & TEST (web + full) ----------
log "Build & Test"
plugin "" superpowers@claude-plugins-official "Superpowers"
if [ -d "$HOME/.claude/skills/gstack" ]; then OK+=("gstack (already there)")
else run "gstack" bash -c 'git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup'
fi
run "graphify" bash -c 'uv tool install graphifyy && graphify install'
npm ls -g vercel >/dev/null 2>&1 || run "Vercel CLI" sudo npm install -g vercel
plugin "" vercel@claude-plugins-official "Vercel plugin"
TODO+=("Vercel: run 'vercel login' once")
mcp_cmd playwright "Playwright MCP" -- npx -y @playwright/mcp@latest --headless
run "Playwright browser" npx -y playwright install --with-deps chromium
npm ls -g @openai/codex >/dev/null 2>&1 || run "Codex CLI" sudo npm install -g @openai/codex
plugin "openai/codex-plugin-cc" codex@openai-codex "Codex plugin"
TODO+=("Codex: run 'codex login', then /codex:setup in claude")
plugin "jarrodwatts/claude-hud" claude-hud@claude-hud "Claude HUD"
TODO+=("Claude HUD: run /claude-hud:setup in claude to turn on the status bar")

# ---------- 2. DESIGN (web + full) ----------
log "Design"
mcp_http figma https://mcp.figma.com/mcp "Figma"
plugin "nextlevelbuilder/ui-ux-pro-max-skill" ui-ux-pro-max@ui-ux-pro-max-skill "ui-ux-pro-max"
skill  "impeccable"      pbakaus/impeccable --skill impeccable
plugin "Leonxlnx/taste-skill" taste-skill@taste-skill "taste-skill"
skill  "emil-design-eng" emilkowalski/skills --skill emil-design-eng
plugin "heygen-com/hyperframes" hyperframes@hyperframes "HyperFrames"
skill  "Remotion skills" remotion-dev/skills
skill  "find-skills"     vercel-labs/skills --skill find-skills

if [ "$PROFILE" = "full" ]; then
  # ---------- 3. RESEARCH & SELL ----------
  log "Research & Sell"
  need_key PERPLEXITY_API_KEY "Perplexity" && \
    mcp_cmd perplexity "Perplexity" -e "PERPLEXITY_API_KEY=$PERPLEXITY_API_KEY" -- npx -y @perplexity-ai/mcp-server
  mcp_http firecrawl https://mcp.firecrawl.dev/v2/mcp-oauth "Firecrawl"
  mcp_http apify     https://mcp.apify.com                  "Apify"
  plugin "mvanhorn/last30days-skill" last30days@last30days-skill "last30days"
  plugin "https://github.com/jordanrendric/claude-video-vision" claude-video-vision@claude-video-vision "Gemini video analyst"
  TODO+=("Video analyst: run /claude-video-vision:setup-video-vision in claude, pick the Gemini backend")
  plugin "blader/humanizer" humanizer@humanizer "humanizer"
  mcp_http metricool https://ai.metricool.com/mcp "Metricool"

  # ---------- 4. MAKE ----------
  log "Make"
  mcp_http higgsfield https://mcp.higgsfield.ai/mcp "Higgsfield (paid plan)"
  need_key OPENAI_API_KEY "GPT Image" && \
    mcp_cmd gpt-image "GPT Image" -e "OPENAI_API_KEY=$OPENAI_API_KEY" -- npx -y @lpenguin/openai-image-mcp
  need_key GEMINI_API_KEY "Nano Banana" && \
    mcp_cmd nano-banana "Nano Banana" -e "GEMINI_API_KEY=$GEMINI_API_KEY" -- npx -y nano-banana-mcp
  mcp_http elevenlabs https://api.elevenlabs.io/v1/mcp "ElevenLabs"
  if need_key GOOGLE_OAUTH_CLIENT_ID "Gmail/Calendar/Drive" && need_key GOOGLE_OAUTH_CLIENT_SECRET "Gmail/Calendar/Drive"; then
    mcp_cmd google-workspace "Gmail + Calendar + Drive" \
      -e "GOOGLE_OAUTH_CLIENT_ID=$GOOGLE_OAUTH_CLIENT_ID" -e "GOOGLE_OAUTH_CLIENT_SECRET=$GOOGLE_OAUTH_CLIENT_SECRET" \
      -- uvx workspace-mcp --tools gmail drive calendar
  fi
  mcp_http granola https://mcp.granola.ai/mcp "Granola"
  if [ "${SKIP_HEAVY:-0}" = "1" ]; then SKIPPED+=("Whisper (SKIP_HEAVY)")
  else run "Whisper" pipx install openai-whisper
  fi

  # ---------- 5. RUN THE OFFICE ----------
  log "Run the Office"
  mcp_http notion https://mcp.notion.com/mcp "Notion"
  plugin "" slack@claude-plugins-official "Slack"
  TODO+=("Slack: a workspace admin must approve the Slack MCP app before sign-in works")
  mcp_http zapier https://mcp.zapier.com/api/v1/connect "Zapier"
  plugin "JuliusBrussee/caveman" caveman@caveman "caveman"
  if [ "${SKIP_HEAVY:-0}" = "1" ]; then SKIPPED+=("Ollama (SKIP_HEAVY)")
  elif have ollama; then OK+=("Ollama (already installed)")
  else run "Ollama" bash -c 'curl -fsSL https://ollama.com/install.sh | sh'
  fi
fi

# ---------- summary ----------
log "Summary"
printf '\033[32mInstalled/ready (%d):\033[0m\n' "${#OK[@]}"; printf '  - %s\n' "${OK[@]}"
[ "${#SKIPPED[@]}" -gt 0 ] && { printf '\033[33mSkipped (%d):\033[0m\n' "${#SKIPPED[@]}"; printf '  - %s\n' "${SKIPPED[@]}"; }
[ "${#FAILED[@]}"  -gt 0 ] && { printf '\033[31mFailed (%d) - re-run or check output above:\033[0m\n' "${#FAILED[@]}"; printf '  - %s\n' "${FAILED[@]}"; }
printf '\n\033[1mStill to do by hand:\033[0m\n'; printf '  - %s\n' "${TODO[@]}"
echo
echo "Start a fresh 'claude' session so everything loads."
