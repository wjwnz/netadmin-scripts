#!/usr/bin/env bash
# ==============================================================================
#  remove-claude-addons.sh   Version 1.0.0   (2026-11-21)
#  Maintained by Bill Walker (Christchurch)
#
#  Trims a machine set up with 'PROFILE=full install-claude-addons.sh' back to the
#  'web' profile: removes the research, social, office and media connectors (they hold
#  sign-ins to outside accounts), caveman, Whisper and Ollama. Build, test and design
#  add-ons are left alone.
#
#  Usage (as your normal user, not root):   bash remove-claude-addons.sh
#  Over SSH use 'ssh -t' so the sudo prompt (Ollama removal) reaches you.
#  Safe to re-run: anything already gone is listed as "Already absent".
#  Removing Ollama also deletes any models it downloaded (/usr/share/ollama).
#
#  1.0.0 First version.
# ==============================================================================

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
command -v claude >/dev/null || { echo "claude not found on PATH"; exit 1; }
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }

DONE=(); GONE=()
note() { if "$@" >/dev/null 2>&1; then DONE+=("${*: -1}"); else GONE+=("${*: -1}"); fi; }

echo "==> Removing MCP servers"
for s in perplexity firecrawl apify metricool gpt-image nano-banana elevenlabs \
         google-workspace granola notion zapier higgsfield; do
  note claude mcp remove --scope user "$s"
done

echo "==> Removing plugins"
for p in last30days@last30days-skill claude-video-vision@claude-video-vision \
         humanizer@humanizer slack@claude-plugins-official caveman@caveman; do
  note claude plugin uninstall "$p"
done
for m in last30days-skill claude-video-vision humanizer caveman; do
  claude plugin marketplace remove "$m" >/dev/null 2>&1 || true
done

echo "==> Removing Whisper"
note pipx uninstall openai-whisper

echo "==> Removing Ollama (needs sudo)"
if command -v ollama >/dev/null 2>&1 || [ -f /etc/systemd/system/ollama.service ]; then
  sudo systemctl disable --now ollama 2>/dev/null || true
  sudo rm -f /etc/systemd/system/ollama.service
  sudo systemctl daemon-reload
  sudo rm -f "$(command -v ollama 2>/dev/null || echo /usr/local/bin/ollama)"
  sudo rm -rf /usr/local/lib/ollama /usr/share/ollama
  # userdel may warn that the group has other members; the groupdel after it still removes it.
  id ollama >/dev/null 2>&1 && sudo userdel ollama
  getent group ollama >/dev/null && sudo groupdel ollama
  DONE+=("ollama")
else
  GONE+=("ollama")
fi

echo
echo "Removed (${#DONE[@]}): ${DONE[*]:-none}"
echo "Already absent (${#GONE[@]}): ${GONE[*]:-none}"
echo
echo "Still installed (skills such as gstack, graphify, impeccable, Remotion are not listed here):"
claude mcp list 2>/dev/null | sed 's/^/  /'
claude plugin list 2>/dev/null | sed 's/^/  /'
echo
echo "Start a fresh 'claude' session for the changes to take effect."
