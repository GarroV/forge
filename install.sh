#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
FORGE_HOME="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="${HOME}/.claude/skills"
AGENTS_DIR="${HOME}/.claude/agents"
PROFILE_DIR="${HOME}/.claude/forge"
mkdir -p "$SKILLS_DIR" "$AGENTS_DIR" "$PROFILE_DIR"
for skill in "$FORGE_HOME"/skills/forge-*/; do
  name="$(basename "$skill")"
  ln -sfn "${skill%/}" "$SKILLS_DIR/$name"
  echo "skill: $name -> linked"
done
# Роли агентов ставятся определениями, а не памяткой в скилле: модель зашита
# во frontmatter, поэтому диспетчер не может забыть её передать.
for agent in "$FORGE_HOME"/agents/forge-*.md; do
  name="$(basename "$agent")"
  ln -sfn "$agent" "$AGENTS_DIR/$name"
  echo "agent: ${name%.md} -> linked"
done
if [[ ! -f "$PROFILE_DIR/profile.md" ]]; then
  template="$(cat "$FORGE_HOME/profile.example.md")"
  printf '%s\n' "${template//__FORGE_HOME__/$FORGE_HOME}" > "$PROFILE_DIR/profile.md"
  echo "profile: created"
else
  echo "profile: exists, skipped"
fi
# Реестр агентов Claude Code собирает при старте сессии: только что связанные
# определения в уже открытой сессии не видны, и попытка запустить блок-агента
# упадёт «agent type not found». Проверено экспериментом 07.08.2026.
echo "ВАЖНО: перезапусти Claude Code — новые определения агентов видны только в новой сессии."
