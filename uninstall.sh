#!/usr/bin/env bash
set -euo pipefail

WITH_CLAUDE=0
for arg in "$@"; do
  case "$arg" in
    --with-claude|--all) WITH_CLAUDE=1 ;;
  esac
done

PLUGIN_DIR="$HOME/.gemini/config/plugins/agy-hud"
CLI_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"

pkill -f "agy-hud/bin/agy-hover-hud" 2>/dev/null || true
rm -rf "$PLUGIN_DIR" "$HOME/.cache/agy-hud" "/tmp/agy-quota-state-$(id -u).json"

if [ -f "$CLI_SETTINGS" ]; then
  python3 - "$CLI_SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f:
    s = json.load(f)
sl = s.get("statusLine")
if isinstance(sl, dict) and "agy-hud" in str(sl.get("command", "")):
    s.pop("statusLine", None)
    with open(p, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
PY
fi

if [ "$WITH_CLAUDE" -eq 1 ]; then
  rm -rf "$HOME/.claude/mods/path-preview"
  echo "Removed optional Claude Code companion."
fi

echo "Uninstalled agy-hud."
