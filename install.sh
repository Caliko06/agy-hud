#!/usr/bin/env bash
set -euo pipefail

WITH_CLAUDE=0
for arg in "$@"; do
  case "$arg" in
    --with-claude|--all) WITH_CLAUDE=1 ;;
    -h|--help)
      echo "Usage: ./install.sh [--with-claude]"
      echo "  (default)      Install agy-hud for Google Antigravity (agy CLI + Antigravity.app)"
      echo "  --with-claude  Also install the optional path-preview companion mod for Claude Code"
      exit 0
      ;;
  esac
done

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$HOME/.gemini/config/plugins/agy-hud"
CLI_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"

command -v clang >/dev/null || { echo "Error: clang not found (run: xcode-select --install)"; exit 1; }
command -v swiftc >/dev/null || { echo "Error: swiftc not found (run: xcode-select --install)"; exit 1; }

if [ "$SRC_DIR" != "$PLUGIN_DIR" ]; then
  mkdir -p "$PLUGIN_DIR/src" "$PLUGIN_DIR/bin" "$PLUGIN_DIR/assets" "$PLUGIN_DIR/sidecars/agy-hud"
  cp "$SRC_DIR/plugin.json" "$PLUGIN_DIR/"
  cp "$SRC_DIR/src/statusline.c" "$SRC_DIR/src/main.swift" "$PLUGIN_DIR/src/"
  cp "$SRC_DIR/assets/logo.svg" "$PLUGIN_DIR/assets/" 2>/dev/null || true
  cp "$SRC_DIR/README.md" "$SRC_DIR/install.sh" "$SRC_DIR/uninstall.sh" "$PLUGIN_DIR/" 2>/dev/null || true
else
  mkdir -p "$PLUGIN_DIR/bin" "$PLUGIN_DIR/sidecars/agy-hud"
fi

echo "Building agy-statusline (C, -O2)..."
clang -O2 -Wall -Wextra "$PLUGIN_DIR/src/statusline.c" -lm -o "$PLUGIN_DIR/bin/agy-statusline"

echo "Building agy-hover-hud (Swift, -O)..."
swiftc -O -framework Cocoa -framework ApplicationServices -framework ImageIO \
  "$PLUGIN_DIR/src/main.swift" -o "$PLUGIN_DIR/bin/agy-hover-hud.new"
mv "$PLUGIN_DIR/bin/agy-hover-hud.new" "$PLUGIN_DIR/bin/agy-hover-hud"
chmod +x "$PLUGIN_DIR/bin/agy-statusline" "$PLUGIN_DIR/bin/agy-hover-hud" "$PLUGIN_DIR/install.sh" "$PLUGIN_DIR/uninstall.sh"

cat > "$PLUGIN_DIR/sidecars/agy-hud/sidecar.json" <<JSON
{
  "display_name": "AGY Hover & Quota HUD",
  "description": "Floating hover preview for images/files in terminals and Antigravity.app + menu bar quota meter",
  "command": "$PLUGIN_DIR/bin/agy-hover-hud",
  "args": [],
  "restart_policy": "on-failure"
}
JSON

mkdir -p "$(dirname "$CLI_SETTINGS")"
python3 - "$CLI_SETTINGS" <<'PY'
import json, os, shutil, sys
p = sys.argv[1]
s = {}
if os.path.exists(p):
    bak = p + ".bak-pre-agy-hud"
    if not os.path.exists(bak):
        shutil.copy2(p, bak)
    with open(p) as f:
        s = json.load(f)
s["statusLine"] = {
    "type": "command",
    "command": "~/.gemini/config/plugins/agy-hud/bin/agy-statusline",
    "stack_with_default": False,
}
with open(p, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
PY

pkill -f "agy-hud/bin/agy-hover-hud" 2>/dev/null || true
if command -v agy >/dev/null; then
  agy plugin validate "$PLUGIN_DIR" || true
fi

if [ "$WITH_CLAUDE" -eq 1 ] && [ -d "$SRC_DIR/claude-code" ]; then
  CLAUDE_MOD_DIR="$HOME/.claude/mods/path-preview"
  mkdir -p "$CLAUDE_MOD_DIR/.claude-plugin" "$CLAUDE_MOD_DIR/hooks"
  cp "$SRC_DIR/claude-code/tsconfig.json" "$CLAUDE_MOD_DIR/"
  cp "$SRC_DIR/claude-code/.claude-plugin/plugin.json" "$CLAUDE_MOD_DIR/.claude-plugin/"
  cp "$SRC_DIR/claude-code/hooks/"* "$CLAUDE_MOD_DIR/hooks/"
  echo "Installed optional Claude Code companion to $CLAUDE_MOD_DIR"
fi

echo ""
echo "Installed agy-hud to $PLUGIN_DIR"
echo "Note: For hover preview, enable Antigravity in System Settings -> Privacy & Security -> Accessibility."
