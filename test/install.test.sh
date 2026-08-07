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
# Предупреждение — часть установки, а не любезность: в уже открытой сессии реестр
# агентов обновляется с задержкой, и первый запуск после установки может упасть
# «agent type not found». Проверяются оба совета, потому что порознь они врут:
# только «повтори» оставит человека в цикле, только «перезапусти» погонит его зря.
install_out="$("$FORGE_HOME/install.sh")"
grep -q "задержкой" <<<"$install_out" || { echo "FAIL: no delay warning"; exit 1; }
grep -q "перезапусти" <<<"$install_out" || { echo "FAIL: no restart fallback"; exit 1; }
echo "PASS"
