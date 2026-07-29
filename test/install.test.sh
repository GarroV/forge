#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
export HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
"$FORGE_HOME/install.sh" > /dev/null
[[ -f "$HOME/.claude/forge/profile.md" ]] || { echo "FAIL: no profile"; exit 1; }
grep -q "forge_home: $FORGE_HOME" "$HOME/.claude/forge/profile.md" || { echo "FAIL: forge_home not substituted"; exit 1; }
echo "custom-marker" >> "$HOME/.claude/forge/profile.md"
"$FORGE_HOME/install.sh" > /dev/null
grep -q "custom-marker" "$HOME/.claude/forge/profile.md" || { echo "FAIL: profile overwritten"; exit 1; }
[[ ! -L "$HOME/.claude/skills/forge-*" ]] || { echo "FAIL: literal glob symlink created"; exit 1; }
for s in "$FORGE_HOME"/skills/forge-*/; do
  name="$(basename "$s")"
  [[ "$(readlink "$HOME/.claude/skills/$name")" == "${s%/}" ]] || { echo "FAIL: symlink $name"; exit 1; }
done
echo "PASS"
