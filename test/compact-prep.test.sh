#!/usr/bin/env bash
set -uo pipefail

# Тесты подготовки к компакту. Компакт для стройки безопасен — состояние лежит в
# файлах, — но приходит он сам и там, где застанет. Опасно окно между «результат
# получен» и «результат записан»: компакт в нём уносит единственную копию, и блок
# принимают заново. Сторож удерживает ход один раз ради записи, как на исходе
# лимита.
#
# Главное, что проверяется, — молчание: порог не задан, контекст мал, транскрипта
# нет, транскрипт испорчен. Лишнее удержание стоит хода модели с полным
# контекстом, то есть настоящих денег.

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
KEEP="$FORGE_HOME/hooks/keep-building.py"
export HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK"' EXIT
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW

passed=0; failed=0
ok()  { passed=$((passed+1)); printf '  ok   %s\n' "$1"; }
bad() { failed=$((failed+1)); printf '  FAIL %s — код %s, вывод: %s\n' "$1" "$CODE" "${OUT:0:160}"; }
expect_hold()    { [[ "$CODE" == 2 ]] && ok "$1" || bad "$1"; }
expect_release() { [[ "$CODE" == 0 ]] && ok "$1" || bad "$1"; }

make_transcript() {
  local name="$1" tokens="$2"
  local path="$WORK/$name.jsonl"
  python3 - "$path" "$tokens" <<'PY'
import json, sys
path, tokens = sys.argv[1], int(sys.argv[2])
rows = [
    {"type": "user", "message": {"role": "user", "content": "строй"}},
    {"type": "assistant", "message": {"role": "assistant", "model": "claude-opus-5",
     "usage": {"input_tokens": 2, "cache_read_input_tokens": tokens - 2,
               "cache_creation_input_tokens": 0, "output_tokens": 100}}},
]
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
  echo "$path"
}

set_window() {
  mkdir -p "$HOME/.claude"
  if [[ "$1" == "none" ]]; then
    echo '{}' > "$HOME/.claude/settings.json"
  else
    python3 -c "
import json,sys,pathlib
p=pathlib.Path(sys.argv[1])/'.claude'/'settings.json'
p.write_text(json.dumps({'autoCompactWindow': int(sys.argv[2])}))" "$HOME" "$1"
  fi
}

call_keep() {
  local dir="$1" transcript="${2:-}"
  local payload
  payload="$(python3 -c "
import json,sys
p={'session_id':'s1','cwd':sys.argv[1],'hook_event_name':'Stop'}
if sys.argv[2]: p['transcript_path']=sys.argv[2]
print(json.dumps(p))" "$dir" "$transcript")"
  OUT="$(printf '%s' "$payload" | python3 "$KEEP" 2>&1)"
  CODE=$?
}

make_project() {
  local dir="$WORK/$1"
  mkdir -p "$dir/docs/forge"
  printf '| id | блок | зависит от | статус | задача |\n|---|---|---|---|---|\n| T001 | api | — | done | Работа |\n' > "$dir/tasks.md"
  echo '# Журнал' > "$dir/progress.md"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" add tasks.md progress.md 2>/dev/null
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  echo "$dir"
}

build="$(make_project build)"
python3 "$KEEP" --start "$build" > /dev/null
big="$(make_transcript big 380000)"
small="$(make_transcript small 90000)"

echo "подготовка к компакту: без заданного порога сторож про компакт молчит"

set_window none
call_keep "$build" "$big"
expect_release "порог автокомпакта не задан — выдумывать его нельзя"

echo "подготовка к компакту: порог задан"

set_window 400000
call_keep "$build" "$small"
expect_release "контекст далеко от порога"

call_keep "$build" "$big"
expect_hold "контекст у порога — ход удержан ради записи состояния"
[[ "$OUT" == *"tasks.md"* && "$OUT" == *"progress.md"* ]] \
  && ok "указание называет, что именно записать" || bad "указание называет, что именно записать"
[[ "$OUT" == *"шагом 1"* ]] \
  && ok "указание требует восстановления по файлам, а не по памяти" \
  || bad "указание требует восстановления по файлам, а не по памяти"

call_keep "$build" "$big"
expect_release "второй раз подряд не удерживает: состояние уже записано"

echo "подготовка к компакту: после компакта готовится заново"

after="$(make_transcript after 120000)"
call_keep "$build" "$after"
expect_release "контекст рухнул — компакт прошёл, флаг снят"
call_keep "$build" "$big"
expect_hold "контекст снова у порога — снова запись состояния"

echo "подготовка к компакту: переменная окружения перебивает настройку"

set_window 400000
CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 call_keep "$build" "$big"
expect_release "при большом окне из переменной 380 тыс. — это далеко от порога"

echo "подготовка к компакту: поломки не удерживают"

call_keep "$build" ""
expect_release "транскрипт не передан"
echo 'мусор не json' > "$WORK/broken.jsonl"
call_keep "$build" "$WORK/broken.jsonl"
expect_release "транскрипт не читается как JSONL"
call_keep "$build" "$WORK/нет-такого.jsonl"
expect_release "транскрипта нет на диске"

printf '\nпройдено %d, провалено %d\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
