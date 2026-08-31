#!/usr/bin/env bash
set -uo pipefail

# Тесты ограничителя ширины волны. Четыре блок-агента, запущенные разом, сожгли
# общий лимит вчетверо быстрее одного и оборвались одновременно — каждый в шаге
# от сдачи, ни один не успел проверить работу (issue #76). Диспетчер заботится о
# портах и стендах, потому что конфликт ресурсов машины виден, а общий лимит
# сессии не виден никому.
#
# Ограничитель обязан быть скупым: он запрещает запуск работы, и ложный запрет
# останавливает стройку целиком. Поэтому вмешательство только вблизи лимита, и
# сначала словом, а не отказом.

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$FORGE_HOME/hooks/guard-wave-width.py"
KEEP="$FORGE_HOME/hooks/keep-building.py"
export HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK"' EXIT

[[ -f "$GUARD" ]] || { echo "FAIL: нет файла ограничителя $GUARD"; exit 1; }

passed=0; failed=0

set_usage() {
  python3 - "$HOME" "$1" <<'USAGE'
import json, os, sys, time
home, pct = sys.argv[1], sys.argv[2]
data = {} if pct == "none" else {"cachedUsageUtilization": {
    "fetchedAtMs": int(time.time() * 1000),
    "utilization": {"five_hour": {"utilization": int(pct), "resets_at": None}}}}
json.dump(data, open(os.path.join(home, ".claude.json"), "w"))
USAGE
}

call_guard() {
  local dir="$1" tool="${2:-Agent}"
  local payload
  payload="$(python3 -c "
import json,sys
print(json.dumps({'session_id':'s1','cwd':sys.argv[1],'hook_event_name':'PreToolUse',
                  'tool_name':sys.argv[2],
                  'tool_input':{'subagent_type':'forge-block-agent','prompt':'бриф'}}))" "$dir" "$tool")"
  GUARD_OUT="$(printf '%s' "$payload" | python3 "$GUARD" 2>/dev/null)"
  GUARD_CODE=$?
}

# Волну обнуляем явно там, где проверяем именно её первый запуск: предыдущие
# блоки теста уже насчитали агентов, и без сброса проверялось бы не то.
reset_wave() {
  python3 - "$HOME" <<'RESET'
import json, os, sys, glob
for f in glob.glob(os.path.join(sys.argv[1], ".claude", "forge", "builds", "*.json")):
    d = json.load(open(f))
    d["wave_launches"] = []
    json.dump(d, open(f, "w"))
RESET
}

ok()   { passed=$((passed+1)); printf '  ok   %s\n' "$1"; }
bad()  { failed=$((failed+1)); printf '  FAIL %s — вывод: %s\n' "$1" "${GUARD_OUT:0:200}"; }
expect_deny()   { [[ "$GUARD_OUT" == *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_warn()   { [[ "$GUARD_OUT" == *"additionalContext"* && "$GUARD_OUT" != *'"deny"'* ]] && ok "$1" || bad "$1"; }
expect_silent() { [[ -z "$GUARD_OUT" ]] && ok "$1" || bad "$1"; }

make_project() {
  local dir="$WORK/$1"
  mkdir -p "$dir/docs/forge"
  printf '| id | блок | зависит от | статус | задача |\n|---|---|---|---|---|\n| T001 | api | — | todo | Работа |\n' > "$dir/tasks.md"
  echo '# Журнал' > "$dir/progress.md"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" add -A 2>/dev/null
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  echo "$dir"
}

echo "ширина волны: вне стройки и вдали от лимита не вмешивается"

p="$(make_project plain)"
set_usage 99
call_guard "$p"
expect_silent "стройки нет — запуск агентов владельца не наше дело"

b="$(make_project build)"
python3 "$KEEP" --start "$b" > /dev/null

set_usage 10
call_guard "$b"
expect_silent "лимит далеко — волна любой ширины разрешена"
call_guard "$b"; call_guard "$b"; call_guard "$b"
expect_silent "четыре запуска подряд при пустом лимите — по-прежнему молчит"

set_usage none
call_guard "$b"
expect_silent "нет данных о лимите — не выдумываем ограничение"

echo
echo "ширина волны: близко к лимиту"

set_usage 75
call_guard "$b"
expect_warn "три четверти окна — предупреждение, но запуск разрешён"
if [[ "$GUARD_OUT" == *"75"* ]]; then ok "в предупреждении названа цифра расхода"; else bad "в предупреждении нет цифры"; fi

# На исходе окна первый агент волны ещё нужен: остановить стройку целиком —
# работа сторожа непрерывности, а не ограничителя ширины.
set_usage 88
reset_wave
call_guard "$b"
expect_warn "первый запуск волны на исходе лимита разрешён, но с предупреждением"
call_guard "$b"
expect_deny "второй запуск в той же волне на исходе лимита запрещён"
if [[ "$GUARD_OUT" == *"дожди"* || "$GUARD_OUT" == *"один"* ]]; then ok "в отказе сказано, что делать вместо этого"; else bad "отказ не говорит, что делать"; fi

echo
echo "ширина волны: волна кончилась — счёт заново"

python3 - "$HOME" <<'AGE'
import json, os, sys, glob, time
# Состаренные запуски: волна, начатая полчаса назад, давно кончилась.
for f in glob.glob(os.path.join(sys.argv[1], ".claude", "forge", "builds", "*.json")):
    d = json.load(open(f))
    d["wave_launches"] = [time.time() - 1800]
    json.dump(d, open(f, "w"))
AGE
call_guard "$b"
expect_warn "старые запуски не считаются текущей волной"

echo
echo "ширина волны: собой ничего не ломает"
set +e
printf 'мусор' | python3 "$GUARD" >/dev/null 2>&1
(( $? == 0 )) && ok "мусор на входе — выход 0" || bad "мусор валит ограничитель"
set -e
call_guard "$b" "Bash"
expect_silent "не запуск агента — ограничитель молчит"

echo
if (( failed == 0 )); then echo "PASS ($passed)"; else echo "ПРОВАЛЕНО: $failed, прошло: $passed"; exit 1; fi
