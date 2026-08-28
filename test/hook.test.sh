#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Тесты сторожа непрерывности стройки. Проверяют не «скрипт запускается», а
# каждое решение, которое он принимает: держать ход или отпустить. Ошибка в любую
# сторону дорогая — не держит вовсе (стройка стоит до владельца, ради чего сторож
# и заведён) или держит всегда (сессия крутится вхолостую и жжёт лимит).

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$FORGE_HOME/hooks/keep-building.py"
export HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$HOME" "$WORK"' EXIT

[[ -f "$HOOK" ]] || { echo "FAIL: нет файла сторожа $HOOK"; exit 1; }

# Собирает проект-фикстуру: git-репозиторий с графом задач.
# $1 — имя, $2 — содержимое строк таблицы задач.
make_project() {
  local dir="$WORK/$1"; shift
  mkdir -p "$dir/docs/forge"
  {
    echo '| id | блок | зависит от | статус | задача |'
    echo '|---|---|---|---|---|'
    printf '%s\n' "$@"
  } > "$dir/tasks.md"
  echo '# Журнал' > "$dir/progress.md"
  git -C "$dir" init -q 2>/dev/null
  git -C "$dir" add -A 2>/dev/null
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  echo "$dir"
}

# Зовёт сторож так же, как его зовёт харнесс: payload на stdin.
# $1 — каталог проекта, $2 — session_id, $3 — json массива background_tasks.
# Печатает код возврата и stderr.
call_hook() {
  local dir="$1" sid="${2:-sess-1}" bg="${3:-[]}"
  local payload
  payload="$(python3 -c "
import json,sys
print(json.dumps({'session_id': sys.argv[1], 'cwd': sys.argv[2],
                  'hook_event_name': 'Stop', 'stop_hook_active': False,
                  'last_assistant_message': 'беру следующую волну',
                  'background_tasks': json.loads(sys.argv[3])}))" "$sid" "$dir" "$bg")"
  set +e
  HOOK_STDERR="$(printf '%s' "$payload" | FORGE_HOOK_TRACE=1 python3 "$HOOK" 2>&1 >/dev/null)"
  HOOK_CODE=$?
  set -e
}

expect_release() {
  (( HOOK_CODE == 0 )) || { echo "FAIL: $1 — ожидался отпуск (0), получен $HOOK_CODE; stderr: $HOOK_STDERR"; exit 1; }
  # Причина обязательна. Первая версия этих тестов её не требовала и оказалась
  # зелёной пустышкой: сторож с выломанной проверкой маркера падал на None,
  # исключение перехватывалось общим обработчиком, наружу шёл тот же код 0 — и
  # проверка «в чужом каталоге молчит» проходила по неверной причине.
  local want="$2"
  grep -q "forge-hook: отпуск" <<<"$HOOK_STDERR" || {
    echo "FAIL: $1 — сторож отпустил ход, не назвав причину; stderr: $HOOK_STDERR"; exit 1; }
  grep -q "сбой сторожа" <<<"$HOOK_STDERR" && {
    echo "FAIL: $1 — сторож отпустил ход из-за сбоя, а не по решению; stderr: $HOOK_STDERR"; exit 1; }
  if [[ -n "$want" ]]; then
    grep -q "$want" <<<"$HOOK_STDERR" || {
      echo "FAIL: $1 — ожидалась причина «${want}», получено: $HOOK_STDERR"; exit 1; }
  fi
}
expect_hold() {
  (( HOOK_CODE == 2 )) || { echo "FAIL: $1 — ожидалось удержание (2), получен $HOOK_CODE"; exit 1; }
}

# 1. Без маркера стройки сторож обязан молчать в любом каталоге. Это его главная
# гарантия безопасности: он стоит глобально и не должен вмешиваться в чужую работу.
plain="$(make_project plain '| T001 | api | — | todo | Что-то сделать |')"
call_hook "$plain"
expect_release "проект без маркера стройки" "нет маркера"

# Не-Forge каталог: нет даже tasks.md — сторож не имеет права падать или держать.
mkdir -p "$WORK/random"; call_hook "$WORK/random"
expect_release "каталог, не являющийся проектом Forge" "нет маркера"

# 2. Маркер поставлен — доступная работа держит ход.
build="$(make_project build '| T001 | api | — | todo | Собрать API |')"
python3 "$HOOK" --start "$build" > /dev/null
call_hook "$build"
expect_hold "маркер стоит, есть задача todo"
grep -q "T001" <<<"$HOOK_STDERR" || { echo "FAIL: в причине удержания не названа доступная задача"; exit 1; }

# 3. Причина удержания обязана говорить, как стройку остановить: иначе владелец,
# которому надо прекратить, не имеет другого выхода, кроме убийства сессии.
grep -q -- "--stop" <<<"$HOOK_STDERR" || { echo "FAIL: в причине удержания не сказано, как остановить"; exit 1; }

# 4. Чужая сессия не удерживается: маркер захватывается первой и принадлежит ей.
call_hook "$build" "sess-другая"
expect_release "сессия, не владеющая маркером" "другой сессии"

# 5. Живой фоновый агент — не держать: сессию разбудит его завершение, а
# удержание заставит диспетчера крутиться вхолостую, пока блок строится.
call_hook "$build" "sess-1" '[{"id":"a1","type":"agent","status":"running","description":"блок api"}]'
expect_release "есть работающая фоновая задача" "фоновая задача"
# Завершённая фоновая задача никого не разбудит — держим.
call_hook "$build" "sess-1" '[{"id":"a1","type":"agent","status":"completed","description":"блок api"}]'
expect_hold "фоновая задача уже завершена"

# 6. Работы нет — отпускаем. Разобрано по каждому статусу, потому что путать их
# дорого: blocked ждёт владельца, failed уже видна ему в сводке, done закрыта.
done_p="$(make_project alldone '| T001 | api | — | done | Готово |')"
python3 "$HOOK" --start "$done_p" > /dev/null; call_hook "$done_p"
expect_release "все задачи done" "работы в графе нет"

blocked_p="$(make_project blocked '| T001 | api | — | blocked:Q001 | Ждёт ответа |')"
python3 "$HOOK" --start "$blocked_p" > /dev/null; call_hook "$blocked_p"
expect_release "единственная задача ждёт ответа владельца" "работы в графе нет"

failed_p="$(make_project failed '| T001 | api | — | failed | Упало |')"
python3 "$HOOK" --start "$failed_p" > /dev/null; call_hook "$failed_p"
expect_release "единственная задача упала" "работы в графе нет"

# 7. Задача, чьи зависимости не закрыты, доступной не является: держать ход
# ради неё — значит гонять диспетчера по кругу над работой, которую нельзя взять.
dep_p="$(make_project deps \
  '| T001 | api | — | blocked:Q001 | Ждёт ответа |' \
  '| T002 | web | T001 | todo | Зависит от незакрытой |')"
python3 "$HOOK" --start "$dep_p" > /dev/null; call_hook "$dep_p"
expect_release "доступна только задача с незакрытой зависимостью" "работы в графе нет"

# 8. Брошенная in_progress без живых агентов — это и есть остановка посреди
# работы: держим.
inp_p="$(make_project inprog '| T001 | api | — | in_progress | Взята и брошена |')"
python3 "$HOOK" --start "$inp_p" > /dev/null; call_hook "$inp_p"
expect_hold "задача in_progress без живого агента"

# 9. Буксование. Стройка не движется — сторож обязан отпустить, а не держать
# вечно: иначе сессия жжёт лимит, повторяя одно и то же, и владелец об этом не
# узнает. Движением считается изменение состояния, а не факт хода.
idle="$(make_project idle '| T001 | api | — | todo | Работа |')"
python3 "$HOOK" --start "$idle" > /dev/null
call_hook "$idle"; expect_hold "буксование: первое удержание"
call_hook "$idle"; expect_hold "буксование: второе удержание"
call_hook "$idle"; expect_hold "буксование: третье удержание"
call_hook "$idle"
expect_release "буксование: состояние не менялось, сторож обязан отпустить" "не двигалась"

# 10. ...а движение обнуляет счётчик: пока стройка идёт, держим сколько нужно.
echo '| T002 | api | — | todo | Ещё работа |' >> "$idle/tasks.md"
call_hook "$idle"
expect_hold "состояние изменилось — счётчик буксования обнулён"
# Причина прошлого отпуска обязана исчезнуть: сводка читает маркер и иначе
# скажет владельцу «стройка отпущена», пока сторож её держит.
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
if d.get('released_reason'):
    print('FAIL: в маркере осталась причина отпуска при работающем удержании:', d['released_reason'])
    raise SystemExit(1)
" "$(python3 "$HOOK" --marker-path "$idle")" || exit 1

# 10а. Коммит сам по себе движением стройки НЕ считается. Это главный рычаг
# защиты от сжигания лимита: в проекте, где забыт маркер, идёт обычная работа —
# правки, коммиты, чужие сессии. Если считать их движением, счётчик буксования
# обнуляется на каждом коммите, и сторож удерживает ход снова и снова, пока не
# упрётся в часовой потолок. Движение стройки — это изменение графа задач, а не
# активность в репозитории.
commits="$(make_project commits '| T001 | api | — | todo | Работа |')"
python3 "$HOOK" --start "$commits" > /dev/null
call_hook "$commits"; expect_hold "коммиты: первое удержание"
call_hook "$commits"; expect_hold "коммиты: второе удержание"
call_hook "$commits"; expect_hold "коммиты: третье удержание"
echo "посторонняя правка" > "$commits/README.md"
git -C "$commits" add -A 2>/dev/null
git -C "$commits" -c user.email=t@t -c user.name=t commit -qm "работа в репозитории" 2>/dev/null
call_hook "$commits"
expect_release "коммит без изменения графа задач не возобновляет удержания" "не двигалась"

# 10б. Абсолютный потолок удержаний на одну стройку. Часового потолка мало:
# стройка, которая движется по графу, но не доходит до конца, может удерживать
# ход сутками. Потолок делает худший случай ограниченным и, главное, заметным.
cap="$(make_project cap '| T001 | api | — | todo | Работа |')"
python3 "$HOOK" --start "$cap" > /dev/null
marker_cap="$(python3 "$HOOK" --marker-path "$cap")"
python3 - "$marker_cap" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["holds"] = 999
json.dump(d, open(sys.argv[1], "w"))
PY
call_hook "$cap"
expect_release "исчерпан общий потолок удержаний на стройку" "потолок"

# 10в. Новая команда стройки возвращает механизм к жизни. Без этого исчерпанный
# потолок остаётся навсегда: следующий прогон идёт без сторожа, и выглядит это
# как работающий механизм, который молча ничего не делает.
python3 "$HOOK" --start "$cap" > /dev/null
call_hook "$cap"
expect_hold "после перезапуска стройки потолок отсчитывается заново"

# 11. Снятый маркер больше не держит: это стоп-кран владельца.
python3 "$HOOK" --stop "$idle" > /dev/null
call_hook "$idle"
expect_release "маркер снят командой --stop" "нет маркера"

# 12. Сторож не имеет права падать на мусоре: любой сбой обязан быть отпуском.
set +e
echo 'не json' | python3 "$HOOK" > /dev/null 2>&1; broken=$?
printf '' | python3 "$HOOK" > /dev/null 2>&1; empty=$?
set -e
(( broken == 0 )) || { echo "FAIL: битый payload дал код $broken вместо 0"; exit 1; }
broken_reason="$(echo 'не json' | FORGE_HOOK_TRACE=1 python3 "$HOOK" 2>&1 >/dev/null)"
grep -q "сбой сторожа" <<<"$broken_reason" || { echo "FAIL: на битом payload сторож не назвал сбой сбоем: $broken_reason"; exit 1; }
(( empty == 0 )) || { echo "FAIL: пустой stdin дал код $empty вместо 0"; exit 1; }

# 12а. Рубильник владельца: одна команда снимает сторожа отовсюду.
off_p="$(make_project offtest '| T001 | api | — | todo | Работа |')"
python3 "$HOOK" --start "$off_p" > /dev/null
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "python3 /куда-то/hooks/keep-building.py" } ] } ],
             "PreToolUse": [ { "hooks": [ { "type": "command", "command": "чужой-хук" } ] } ] } }
JSON
python3 "$HOOK" --off > /dev/null
call_hook "$off_p"
expect_release "после --off сторож не держит ничего" "нет маркера"
grep -q "keep-building" "$HOME/.claude/settings.json" && { echo "FAIL: --off не снял регистрацию"; exit 1; }
grep -q "чужой-хук" "$HOME/.claude/settings.json" || { echo "FAIL: --off снёс чужой хук"; exit 1; }

# 13. Забытый маркер не держит вечно: стройка недельной давности — это не стройка.
old="$(make_project old '| T001 | api | — | todo | Работа |')"
python3 "$HOOK" --start "$old" > /dev/null
marker="$(python3 "$HOOK" --marker-path "$old")"
python3 - "$marker" <<'PY'
import json, sys, datetime
p = sys.argv[1]
d = json.load(open(p))
d['started_at'] = (datetime.datetime.now() - datetime.timedelta(days=30)).isoformat()
json.dump(d, open(p, 'w'))
PY
call_hook "$old"
expect_release "маркер стройки просрочен" "просрочен"

echo "PASS"
