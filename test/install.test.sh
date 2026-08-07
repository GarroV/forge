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
# Определения агентов ставятся тем же установщиком: без них скиллы называют типы
# агентов, которых в реестре нет, и запуск блока падает «agent type not found».
[[ ! -L "$HOME/.claude/agents/forge-*.md" ]] || { echo "FAIL: literal glob symlink created (agents)"; exit 1; }
agents_found=0
for a in "$FORGE_HOME"/agents/forge-*.md; do
  name="$(basename "$a")"
  [[ "$(readlink "$HOME/.claude/agents/$name")" == "$a" ]] || { echo "FAIL: agent symlink $name"; exit 1; }
  agents_found=1
done
(( agents_found == 1 )) || { echo "FAIL: no agent definitions linked"; exit 1; }
# Предупреждение о перезапуске — часть установки, а не любезность: реестр агентов
# Claude Code собирает на старте сессии, в уже открытой новые определения не видны.
"$FORGE_HOME/install.sh" | grep -q "перезапусти" || { echo "FAIL: no restart warning"; exit 1; }
echo "PASS"
