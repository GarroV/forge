#!/usr/bin/env bash
set -uo pipefail

# Тесты стража изображений. Скриншот, прочитанный дорогой ролью, — самый дорогой
# объект в контексте: замер стройки dodo_qr_service дал 40 снимков, удержание
# которых стоило 20% всего расхода блок-агентов (132 млн токенов чтения кэша на
# opus). Страж переносит сверку в роль forge-visual-checker на sonnet.
#
# Страж запрещает чтение, а ложный запрет ломает работу владельца в его
# собственной сессии. Поэтому проверяется прежде всего молчание: вне стройки, на
# мелком файле, на не-изображении и на любой поломке страж обязан пропускать.

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$FORGE_HOME/hooks/guard-image-reads.py"
KEEP="$FORGE_HOME/hooks/keep-building.py"
export HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK"' EXIT

[[ -f "$GUARD" ]] || { echo "FAIL: нет файла стража $GUARD"; exit 1; }

passed=0; failed=0

ok()   { passed=$((passed+1)); printf '  ok   %s\n' "$1"; }
bad()  { failed=$((failed+1)); printf '  FAIL %s — вывод: %s\n' "$1" "${GUARD_OUT:0:200}"; }
expect_deny()   { [[ "$GUARD_OUT" == *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_silent() { [[ -z "$GUARD_OUT" ]] && ok "$1" || bad "$1"; }
expect_text()   { [[ "$GUARD_OUT" == *"$2"* ]] && ok "$1" || bad "$1"; }

# Транскрипт роли: субагент пишет в subagents/agent-<id>.jsonl, рядом meta.json с
# agentType. Это единственный признак роли, доступный хуку.
make_role() {
  local role="$1" dir="$WORK/transcripts/subagents"
  mkdir -p "$dir"
  printf '{"agentType":"%s","spawnDepth":1}' "$role" > "$dir/agent-$role.meta.json"
  : > "$dir/agent-$role.jsonl"
  echo "$dir/agent-$role.jsonl"
}

make_file() {
  local name="$1" kb="$2"
  local path="$WORK/$name"
  mkdir -p "$(dirname "$path")"
  dd if=/dev/zero of="$path" bs=1024 count="$kb" 2>/dev/null
  echo "$path"
}

call_guard() {
  local dir="$1" file="$2" transcript="${3:-}" tool="${4:-Read}"
  local payload
  payload="$(python3 -c "
import json,sys
p={'session_id':'s1','cwd':sys.argv[1],'hook_event_name':'PreToolUse',
   'tool_name':sys.argv[3],'tool_input':{'file_path':sys.argv[2]}}
if sys.argv[4]: p['transcript_path']=sys.argv[4]
print(json.dumps(p))" "$dir" "$file" "$tool" "$transcript")"
  GUARD_OUT="$(printf '%s' "$payload" | python3 "$GUARD" 2>/dev/null)"
}

make_project() {
  local dir="$WORK/$1"
  mkdir -p "$dir/docs/forge"
  printf '| id | блок | зависит от | статус | задача |\n|---|---|---|---|---|\n| T001 | api | — | todo | Работа |\n' > "$dir/tasks.md"
  echo '# Журнал' > "$dir/progress.md"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" add tasks.md progress.md 2>/dev/null
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  echo "$dir"
}

shot="$(make_file shots/screen.png 300)"
tiny="$(make_file shots/icon.png 20)"
doc="$(make_file docs/note.md 300)"

echo "страж изображений: вне стройки не вмешивается"

plain="$(make_project plain)"
call_guard "$plain" "$shot"
expect_silent "стройки нет — владелец читает свой снимок беспрепятственно"

build="$(make_project build)"
python3 "$KEEP" --start "$build" > /dev/null

echo "страж изображений: на стройке"

call_guard "$build" "$shot"
expect_deny "крупный снимок в контекст диспетчера не идёт"

call_guard "$build" "$shot" "$(make_role forge-block-agent)"
expect_deny "блок-агент на opus — та самая роль, ради которой правило написано"

call_guard "$build" "$shot" "$(make_role forge-executor)"
expect_deny "исполнителю картинка тоже не нужна: у него механическая задача"

call_guard "$build" "$shot" "$(make_role forge-visual-checker)"
expect_silent "роль сверки смотрит картинки — она для этого и заведена"

call_guard "$build" "$tiny"
expect_silent "мелкий файл дешевле запрета"

call_guard "$build" "$doc"
expect_silent "не изображение — не наше дело"

call_guard "$build" "$WORK/shots/absent.png"
expect_silent "нет файла — разбирается Read, а не страж"

call_guard "$build" "$shot" "" "Bash"
expect_silent "другой инструмент — мимо"

echo "страж изображений: поломки разрешают, а не запрещают"

GUARD_OUT="$(printf 'не json' | python3 "$GUARD" 2>/dev/null)"
expect_silent "испорченный payload"

GUARD_OUT="$(printf '{}' | python3 "$GUARD" 2>/dev/null)"
expect_silent "пустой payload"

GUARD_OUT="$(printf '{"tool_name":"Read","tool_input":{}}' | python3 "$GUARD" 2>/dev/null)"
expect_silent "Read без пути"

echo "страж изображений: отказ называет замену"

call_guard "$build" "$shot"
expect_text "в отказе названа роль, которая сделает сверку" "forge-visual-checker"
expect_text "отказ требует сделать сверку, а не отменить её" "не пропускай"
expect_text "отказ называет цену словами владельца" "20%"

printf '\nпройдено %d, провалено %d\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
