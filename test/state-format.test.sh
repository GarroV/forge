#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"

id_in_list() {
  # $1 = искомый id, $2 = список id (по одному на строку)
  grep -qxF "$1" <<< "$2"
}

# Прогоняет все проверки ссылочной целостности по одной фикстуре.
# Завершает весь скрипт (exit 1) при первом найденном нарушении.
check_fixture() {
  local FIXTURE="$1"
  local TASKS="$FIXTURE/tasks.md"
  local QUESTIONS="$FIXTURE/docs/forge/questions.md"
  local DECISIONS="$FIXTURE/docs/forge/decisions.md"
  local PROGRESS="$FIXTURE/progress.md"

  for f in "$TASKS" "$QUESTIONS" "$DECISIONS" "$PROGRESS"; do
    [[ -f "$f" ]] || { echo "FAIL: [$FIXTURE] файл не найден: $f"; exit 1; }
  done

  # id, реально определённые в каждом файле (только строки таблицы вида "| Xnnn |
  # ...", закомментированные строки-примеры <!-- --> в счёт не идут).
  local task_ids question_ids decision_ids
  task_ids="$(grep -oE '^\| *T[0-9]{3} *\|' "$TASKS" | grep -oE 'T[0-9]{3}' || true)"
  question_ids="$(grep -oE '^\| *Q[0-9]{3} *\|' "$QUESTIONS" | grep -oE 'Q[0-9]{3}' || true)"
  decision_ids="$(grep -oE '^\| *D[0-9]{3} *\|' "$DECISIONS" | grep -oE 'D[0-9]{3}' || true)"

  # Проверка 1: все id из колонки "блокирует" (questions.md) существуют в tasks.md
  local row qid blocks_field refs ref
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    qid="$(awk -F'|' '{print $2}' <<< "$row" | xargs)"
    blocks_field="$(awk -F'|' '{print $4}' <<< "$row" | xargs)"
    [[ -z "$blocks_field" || "$blocks_field" == "—" ]] && continue
    IFS=',' read -ra refs <<< "$blocks_field"
    for ref in "${refs[@]}"; do
      ref="$(echo "$ref" | xargs)"
      [[ -z "$ref" ]] && continue
      if ! id_in_list "$ref" "$task_ids"; then
        echo "FAIL: [$FIXTURE] questions.md ($qid): в колонке «блокирует» указана несуществующая задача $ref"
        exit 1
      fi
    done
  done < <(grep -E '^\| *Q[0-9]{3} *\|' "$QUESTIONS" || true)

  # Проверка 2: все blocked:Qnnn в tasks.md существуют в questions.md
  local qref
  while IFS= read -r qref; do
    [[ -z "$qref" ]] && continue
    if ! id_in_list "$qref" "$question_ids"; then
      echo "FAIL: [$FIXTURE] tasks.md ссылается на несуществующий вопрос blocked:$qref"
      exit 1
    fi
  done < <(grep -oE 'blocked:Q[0-9]{3}' "$TASKS" | grep -oE 'Q[0-9]{3}' || true)

  # Проверка 3: все ссылки Dnnn (например, в "ответ" вопроса со статусом auto)
  # существуют в decisions.md
  local dref
  while IFS= read -r dref; do
    [[ -z "$dref" ]] && continue
    if ! id_in_list "$dref" "$decision_ids"; then
      echo "FAIL: [$FIXTURE] найдена ссылка на несуществующее решение $dref"
      exit 1
    fi
  done < <(grep -ohE 'D[0-9]{3}' "$TASKS" "$QUESTIONS" "$PROGRESS" || true)

  # Проверка 4: все id из колонки "зависит от" (tasks.md) существуют в tasks.md
  local tid deps_field deps dep
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    tid="$(awk -F'|' '{print $2}' <<< "$row" | xargs)"
    deps_field="$(awk -F'|' '{print $4}' <<< "$row" | xargs)"
    [[ -z "$deps_field" || "$deps_field" == "—" ]] && continue
    IFS=',' read -ra deps <<< "$deps_field"
    for dep in "${deps[@]}"; do
      dep="$(echo "$dep" | xargs)"
      [[ -z "$dep" ]] && continue
      if ! id_in_list "$dep" "$task_ids"; then
        echo "FAIL: [$FIXTURE] tasks.md ($tid): в колонке «зависит от» указана несуществующая задача $dep"
        exit 1
      fi
    done
  done < <(grep -E '^\| *T[0-9]{3} *\|' "$TASKS" || true)

  # Проверка 5: у каждого блока, который уже работал (есть задача в статусе
  # in_progress/done/failed), в progress.md есть запись о запуске с ролью и
  # моделью. Без неё не видно, какой ролью и какой моделью шла работа: именно так
  # роль исполнителя не запускалась две стройки подряд и никто этого не замечал.
  #
  # Требование не задним числом: оно действует с той строки журнала, где стоит
  # маркер формата. Журнал без маркера велся до появления правила — блоки в нём
  # проверять не по чему, и валить из-за этого работающую стройку нельзя (красная
  # проверка по контракту скилла означает «стоп»). Пропуск не молчаливый: о нём
  # печатается строка.
  local marker_line
  # `|| true` обязателен: без совпадения grep возвращает 1, а под `set -e` с
  # `pipefail` это убивает весь прогон молча — с пустым выводом и кодом 1.
  marker_line="$(grep -nF 'Формат журнала: с этой строки каждый запуск агента записывается с ролью и моделью' "$PROGRESS" | head -1 | cut -d: -f1 || true)"

  if [[ -z "$marker_line" ]]; then
    echo "NOTE: [$FIXTURE] в progress.md нет маркера формата — записи о запуске не проверяются (журнал до правила)"
  else
    local worked_blocks block first_mention
    worked_blocks="$(grep -E '^\| *T[0-9]{3} *\|' "$TASKS" \
      | awk -F'|' '{gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$5);
                    if ($3 != "chores" && ($5 == "in_progress" || $5 == "done" || $5 == "failed")) print $3}' \
      | sort -u)"
    while IFS= read -r block; do
      [[ -z "$block" ]] && continue
      # Блок, начатый до маркера, под правило не попадает: его запуска в журнале
      # быть не могло.
      first_mention="$(grep -nF "$block" "$PROGRESS" | head -1 | cut -d: -f1 || true)"
      if [[ -n "$first_mention" && "$first_mention" -lt "$marker_line" ]]; then
        continue
      fi
      if ! grep -qE "Запущен блок ${block}: роль [A-Za-z0-9_-]+, модель [^ ,]+" "$PROGRESS"; then
        echo "FAIL: [$FIXTURE] progress.md: нет записи о запуске блока $block с ролью и моделью"
        exit 1
      fi
    done <<< "$worked_blocks"
  fi

  # Проверка 6: файл состояния, лежащий не по своему каноническому пути.
  # Канон один: `tasks.md` и `progress.md` — в корне проекта, `questions.md` и
  # `decisions.md` — в `docs/forge/`. Двойник по зеркальному пути не ломает
  # ничего сразу и потому опаснее поломки: сессия читает файл по имени, получает
  # не тот, и восстанавливает по нему картину — а перечитывать код ради проверки
  # ей запрещено скиллом стройки. Проверено на живом прогоне (`dodo_pnl_service`,
  # 21.08.2026): рядом с корневым `progress.md` завёлся `docs/forge/progress.md`,
  # журнал уехал в него, корневой отстал на три дня, и заметил это владелец, а не
  # система.
  local canonical wrong
  for pair in "tasks.md:docs/forge/tasks.md" \
              "progress.md:docs/forge/progress.md" \
              "docs/forge/questions.md:questions.md" \
              "docs/forge/decisions.md:decisions.md"; do
    canonical="${pair%%:*}"
    wrong="${pair##*:}"
    if [[ -e "$FIXTURE/$wrong" ]]; then
      echo "FAIL: [$FIXTURE] файл состояния лежит не по своему пути: $wrong (канон — $canonical)."
      echo "      Двойник читается вместо канонического и молча даёт устаревшую картину."
      exit 1
    fi
  done

  # Проверка 7: цикл в зависимостях. Висячая ссылка ловится проверкой 4, но граф
  # может быть ссылочно целым и всё равно нерабочим: задачи, замкнутые в кольцо,
  # не станут доступными никогда, а диспетчер будет честно сообщать «нечего
  # брать». Снаружи это выглядит как законченная стройка.
  local remaining resolved progress_made node node_deps dep_ok
  remaining="$task_ids"
  while [[ -n "$remaining" ]]; do
    progress_made=0
    resolved=""
    while IFS= read -r node; do
      [[ -z "$node" ]] && continue
      node_deps="$(grep -E "^\| *${node} *\|" "$TASKS" | awk -F'|' '{print $4}' | xargs || true)"
      dep_ok=1
      if [[ -n "$node_deps" && "$node_deps" != "—" ]]; then
        IFS=',' read -ra deps <<< "$node_deps"
        for dep in "${deps[@]}"; do
          dep="$(echo "$dep" | xargs)"
          [[ -z "$dep" ]] && continue
          if id_in_list "$dep" "$remaining"; then dep_ok=0; fi
        done
      fi
      if (( dep_ok == 1 )); then progress_made=1; else resolved="$resolved$node\n"; fi
    done <<< "$remaining"
    if (( progress_made == 0 )); then
      echo "FAIL: [$FIXTURE] tasks.md: зависимости замкнуты в цикл, эти задачи не станут доступными никогда:"
      echo "$remaining" | tr '\n' ' '
      echo
      exit 1
    fi
    remaining="$(printf '%b' "$resolved" | sed '/^$/d')"
  done

  # Проверки 8 и 9: состав блоков в графе и в пакете документов обязан совпадать.
  # Источник истины о том, какие блоки есть, — файлы описаний `docs/forge/blocks/*.md`.
  # Оба расхождения тихие и оба измерены на живом прогоне: блок, объявленный без
  # единой задачи, делает заявленную цель недостижимой (диспетчеру нечего раздать,
  # а граф выглядит целым), а блок, который строится без описания в пакете,
  # диспетчер не увидит вовсе — он раздаёт работу по плану. На одном прогоне план
  # знал девять блоков, а журналы велись по двадцати трём.
  local BLOCKS_DIR="$FIXTURE/docs/forge/blocks"
  if [[ ! -d "$BLOCKS_DIR" ]]; then
    echo "NOTE: [$FIXTURE] нет docs/forge/blocks/ — состав блоков не проверяется"
  else
    local declared graph_blocks blk
    declared="$(for f in "$BLOCKS_DIR"/*.md; do [[ -e "$f" ]] || continue; basename "$f" .md; done | sort -u)"
    graph_blocks="$(grep -E '^\| *T[0-9]{3} *\|' "$TASKS" \
      | awk -F'|' '{gsub(/^ +| +$/,"",$3); if ($3 != "chores" && $3 != "") print $3}' | sort -u)"

    while IFS= read -r blk; do
      [[ -z "$blk" ]] && continue
      grep -qxF "$blk" <<< "$graph_blocks" || {
        echo "FAIL: [$FIXTURE] блок $blk объявлен в docs/forge/blocks/, но в графе нет ни одной его задачи"
        echo "      Цель, ради которой он заведён, недостижима: диспетчеру нечего раздать."
        exit 1
      }
    done <<< "$declared"

    while IFS= read -r blk; do
      [[ -z "$blk" ]] && continue
      grep -qxF "$blk" <<< "$declared" || {
        echo "FAIL: [$FIXTURE] блок $blk есть в графе задач, но не объявлен в docs/forge/blocks/"
        echo "      Диспетчер раздаёт работу по пакету документов — этот блок он не увидит."
        exit 1
      }
    done <<< "$graph_blocks"
  fi

  echo "PASS: $FIXTURE"
}

if [[ $# -ge 1 ]]; then
  # Явный путь к одной фикстуре — используется экспериментами с испорченными
  # копиями (см. test-fixtures в mktemp).
  [[ -d "$1" ]] || { echo "FAIL: каталог фикстуры не найден: $1"; exit 1; }
  check_fixture "$(cd "$1" && pwd)"
  echo "PASS"
  exit 0
fi

# Без аргумента — проверяем ВСЕ фикстуры в test/fixtures/*/.
found=0
for dir in "$FORGE_HOME"/test/fixtures/*/; do
  found=1
  check_fixture "${dir%/}"
done

[[ "$found" -eq 1 ]] || { echo "FAIL: не найдено ни одной фикстуры в test/fixtures/"; exit 1; }

echo "PASS"
