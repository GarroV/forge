#!/usr/bin/env bash
set -uo pipefail

# Тесты стража состава коммита. Правило «коммить перечислением путей» записано в
# скилле и в брифе блок-агента подробно, с примерами и купленными уроками — и
# было нарушено дважды за три дня. Значит проза не работает и нужен механизм;
# эти тесты проверяют именно его решения.
#
# Ошибка в любую сторону дорогая: пропустил сплошной add — чужие файлы уезжают в
# чужой коммит под чужим сообщением (issue #78); запретил лишнего — стройка
# встаёт на ровном месте, потому что коммитить ей больше нечем.

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$FORGE_HOME/hooks/guard-commit-scope.py"
KEEP="$FORGE_HOME/hooks/keep-building.py"
export HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK"' EXIT

[[ -f "$GUARD" ]] || { echo "FAIL: нет файла стража $GUARD"; exit 1; }

passed=0; failed=0

# Зовёт страж так же, как его зовёт харнесс.
# $1 — каталог, $2 — команда, $3 — имя инструмента (по умолчанию Bash).
call_guard() {
  local dir="$1" cmd="$2" tool="${3:-Bash}"
  local payload
  payload="$(python3 -c "
import json,sys
print(json.dumps({'session_id':'s1','cwd':sys.argv[1],'hook_event_name':'PreToolUse',
                  'tool_name':sys.argv[3],'tool_input':{'command':sys.argv[2]}}))" "$dir" "$cmd" "$tool")"
  GUARD_OUT="$(printf '%s' "$payload" | python3 "$GUARD" 2>/dev/null)"
  GUARD_CODE=$?
}

expect_deny() {
  local name="$1"
  if [[ "$GUARD_OUT" == *'"deny"'* ]]; then
    passed=$((passed+1)); printf '  ok   %s\n' "$name"
  else
    failed=$((failed+1)); printf '  FAIL %s — ждали запрет, получили: %s\n' "$name" "${GUARD_OUT:0:160}"
  fi
}

expect_allow() {
  local name="$1"
  if [[ "$GUARD_OUT" == *'"deny"'* ]]; then
    failed=$((failed+1)); printf '  FAIL %s — страж запретил то, что должен пропускать: %s\n' "$name" "${GUARD_OUT:0:160}"
  else
    passed=$((passed+1)); printf '  ok   %s\n' "$name"
  fi
}

expect_silent() {
  local name="$1"
  if [[ -z "$GUARD_OUT" ]]; then
    passed=$((passed+1)); printf '  ok   %s\n' "$name"
  else
    failed=$((failed+1)); printf '  FAIL %s — ждали молчание, получили: %s\n' "$name" "${GUARD_OUT:0:160}"
  fi
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

echo "страж состава коммита: вне стройки не вмешивается"

plain="$(make_project plain)"
call_guard "$plain" "git add -A"
expect_silent "стройки нет — сплошной add владельца не трогаем"
call_guard "$plain" "git commit -am 'что угодно'"
expect_silent "стройки нет — commit -a владельца не трогаем"

echo
echo "страж состава коммита: во время стройки"

b="$(make_project build)"
python3 "$KEEP" --start "$b" > /dev/null

call_guard "$b" "git add -A"
expect_deny "git add -A"
call_guard "$b" "git add ."
expect_deny "git add ."
call_guard "$b" "git add --all"
expect_deny "git add --all"
call_guard "$b" "git add -u"
expect_deny "git add -u (все отслеживаемые — тот же сплошной захват)"
call_guard "$b" "git commit -am 'сообщение'"
expect_deny "git commit -am"
call_guard "$b" "git commit -a -m 'сообщение'"
expect_deny "git commit -a"
call_guard "$b" "cd /tmp && git add -A && git commit -m x"
expect_deny "сплошной add в середине цепочки команд"
call_guard "$b" "git   add    -A"
expect_deny "лишние пробелы не обходят стража"

# Ложные срабатывания дороже пропусков в одном смысле: страж, мешающий работать,
# будет снят целиком, и тогда не поймает уже ничего.
call_guard "$b" "git add tasks.md progress.md"
expect_allow "перечисление путей — штатный способ, проходит"
call_guard "$b" "git add .gitignore"
expect_allow ".gitignore — путь, а не «всё дерево»"
call_guard "$b" "git add ./src/api.py"
expect_allow "относительный путь с точкой в начале"
call_guard "$b" "git commit --amend --no-edit"
expect_allow "--amend не сплошной, это правка последнего коммита"
call_guard "$b" "git status"
expect_silent "не add и не commit — страж молчит"
call_guard "$b" "ls -la"
expect_silent "не git вовсе"
call_guard "$b" "git add -A" "Edit"
expect_silent "другой инструмент — страж не при делах"

echo
echo "страж состава коммита: сверка индекса перед коммитом"

# Запрет сплошного add снимает корень, но промахнуться путём можно и вручную.
# Поэтому на самом коммите страж показывает фактический состав индекса — не
# запрещая: сверить список обязан тот, кто пишет сообщение коммита.
echo "чужое" > "$b/посторонний.txt"
git -C "$b" add "посторонний.txt" 2>/dev/null
call_guard "$b" "git commit -m 'волна принята'"
expect_allow "обычный commit не запрещается"
if [[ "$GUARD_OUT" == *"посторонний.txt"* ]]; then
  passed=$((passed+1)); printf '  ok   в контекст попал фактический состав индекса\n'
else
  failed=$((failed+1)); printf '  FAIL состав индекса не показан перед коммитом: %s\n' "${GUARD_OUT:0:200}"
fi

echo
echo "страж состава коммита: собой ничего не ломает"

set +e
printf 'не json' | python3 "$GUARD" >/dev/null 2>&1
(( $? == 0 )) && { passed=$((passed+1)); printf '  ok   мусор на входе — выход 0\n'; } || { failed=$((failed+1)); printf '  FAIL мусор на входе валит страж\n'; }
printf '' | python3 "$GUARD" >/dev/null 2>&1
(( $? == 0 )) && { passed=$((passed+1)); printf '  ok   пустой вход — выход 0\n'; } || { failed=$((failed+1)); printf '  FAIL пустой вход валит страж\n'; }
call_guard "$WORK/нет-такого-каталога" "git add -A"
(( GUARD_CODE == 0 )) && { passed=$((passed+1)); printf '  ok   несуществующий каталог — выход 0\n'; } || { failed=$((failed+1)); printf '  FAIL несуществующий каталог валит страж\n'; }
set -e

echo
if (( failed == 0 )); then echo "PASS ($passed)"; else echo "ПРОВАЛЕНО: $failed, прошло: $passed"; exit 1; fi
