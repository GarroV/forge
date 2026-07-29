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
