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
# Реестр агентов в уже открытой сессии обновляется, но с задержкой: сразу после
# появления файла запуск падает «agent type not found», через некоторое время тот же
# агент доступен без перезапуска. Проверено дважды 07.08.2026 — сначала падением на
# только что созданном определении, потом его же успешным запуском в той же сессии.
# Поэтому здесь не «перезапусти обязательно», а «повтори, потом перезапусти»:
# обещать перезапуск как единственный путь — значит гонять человека зря.
echo "Новые определения агентов в уже открытых сессиях подхватываются с задержкой."
echo "Упало «agent type not found» — повтори чуть позже; не помогло — перезапусти Claude Code."
