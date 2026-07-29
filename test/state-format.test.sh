#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${1:-$FORGE_HOME/test/fixtures/toy-project}"

TASKS="$FIXTURE/tasks.md"
QUESTIONS="$FIXTURE/docs/forge/questions.md"
DECISIONS="$FIXTURE/docs/forge/decisions.md"
PROGRESS="$FIXTURE/progress.md"

for f in "$TASKS" "$QUESTIONS" "$DECISIONS" "$PROGRESS"; do
  [[ -f "$f" ]] || { echo "FAIL: файл не найден: $f"; exit 1; }
done

# id, реально определённые в каждом файле (только строки таблицы вида "| Xnnn |
# ...", закомментированные строки-примеры <!-- --> в счёт не идут).
task_ids="$(grep -oE '^\| *T[0-9]{3} *\|' "$TASKS" | grep -oE 'T[0-9]{3}' || true)"
question_ids="$(grep -oE '^\| *Q[0-9]{3} *\|' "$QUESTIONS" | grep -oE 'Q[0-9]{3}' || true)"
decision_ids="$(grep -oE '^\| *D[0-9]{3} *\|' "$DECISIONS" | grep -oE 'D[0-9]{3}' || true)"

id_in_list() {
  # $1 = искомый id, $2 = список id (по одному на строку)
  grep -qxF "$1" <<< "$2"
}

# Проверка 1: все id из колонки "блокирует" (questions.md) существуют в tasks.md
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
      echo "FAIL: questions.md ($qid): в колонке «блокирует» указана несуществующая задача $ref"
      exit 1
    fi
  done
done < <(grep -E '^\| *Q[0-9]{3} *\|' "$QUESTIONS" || true)

# Проверка 2: все blocked:Qnnn в tasks.md существуют в questions.md
while IFS= read -r qref; do
  [[ -z "$qref" ]] && continue
  if ! id_in_list "$qref" "$question_ids"; then
    echo "FAIL: tasks.md ссылается на несуществующий вопрос blocked:$qref"
    exit 1
  fi
done < <(grep -oE 'blocked:Q[0-9]{3}' "$TASKS" | grep -oE 'Q[0-9]{3}' || true)

# Проверка 3: все ссылки Dnnn (например, в "ответ" вопроса со статусом auto)
# существуют в decisions.md
while IFS= read -r dref; do
  [[ -z "$dref" ]] && continue
  if ! id_in_list "$dref" "$decision_ids"; then
    echo "FAIL: найдена ссылка на несуществующее решение $dref"
    exit 1
  fi
done < <(grep -ohE 'D[0-9]{3}' "$TASKS" "$QUESTIONS" "$PROGRESS" || true)

echo "PASS"
