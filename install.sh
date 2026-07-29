#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
FORGE_HOME="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="${HOME}/.claude/skills"
PROFILE_DIR="${HOME}/.claude/forge"
mkdir -p "$SKILLS_DIR" "$PROFILE_DIR"
for skill in "$FORGE_HOME"/skills/forge-*/; do
  name="$(basename "$skill")"
  ln -sfn "${skill%/}" "$SKILLS_DIR/$name"
  echo "skill: $name -> linked"
done
if [[ ! -f "$PROFILE_DIR/profile.md" ]]; then
  template="$(cat "$FORGE_HOME/profile.example.md")"
  printf '%s\n' "${template//__FORGE_HOME__/$FORGE_HOME}" > "$PROFILE_DIR/profile.md"
  echo "profile: created"
else
  echo "profile: exists, skipped"
fi
