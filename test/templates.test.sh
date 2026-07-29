#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
# По умолчанию проверяются реальные шаблоны репо; аргумент — каталог с копией
# (используется экспериментами с испорченными копиями, см. mktemp в отчёте).
TEMPLATES_DIR="${1:-$FORGE_HOME/templates}"
MAX_LINES=100

check_lines() {
  local file="$1" path="$2" lines
  lines="$(wc -l < "$path" | tr -d ' ')"
  if (( lines > MAX_LINES )); then
    echo "FAIL: $file превышает лимит $MAX_LINES строк (найдено $lines)"
    exit 1
  fi
}

check_sections() {
  # $1 = имя файла (для сообщений), $2 = путь, далее — обязательные секции ("## <секция>")
  local file="$1" path="$2"
  shift 2
  local section
  for section in "$@"; do
    grep -qF "## $section" "$path" || {
      echo "FAIL: [$file] отсутствует обязательная секция: $section"
      exit 1
    }
  done
}

check_template() {
  # $1 = имя файла шаблона, далее — его обязательные секции
  local file="$1" path="$TEMPLATES_DIR/$1"
  shift
  [[ -f "$path" ]] || { echo "FAIL: шаблон не найден: $path"; exit 1; }
  check_lines "$file" "$path"
  check_sections "$file" "$path" "$@"
}

# Список секций — дословно из брифа Task 4 (Interfaces).
check_template constitution.md \
  "Принципы качества" "Тестовый стандарт" "Docs-as-DoD" "Правила безопасности" "Демо-режим"

check_template spec.md \
  "Обзор" "Пользователи и сценарии" "User stories с приоритетами" "DoD MVP" "Что НЕ делаем" "Открытые вопросы"

check_template plan.md \
  "Стек с обоснованием" "Архитектура" "Блоки и граф зависимостей" "Контракты между блоками" "Риски"

check_template block.md \
  "Назначение" "API-контракт" "Зависимости" "Definition of Done блока" "Статус"

check_template research-report.md \
  "Готовые решения" "Рынок и референсы" "Стек и версии" "Развилки для брейншторма"

# research-report.md: секция «Развилки для брейншторма» обязана быть нумерованным списком.
grep -qE '^[0-9]+\.' "$TEMPLATES_DIR/research-report.md" || {
  echo "FAIL: research-report.md — «Развилки для брейншторма» не содержит нумерованного списка"
  exit 1
}

# plan.md: граф зависимостей — каркас блока ```mermaid (не выдуманный граф).
grep -qF '```mermaid' "$TEMPLATES_DIR/plan.md" || {
  echo "FAIL: plan.md — отсутствует каркас \`\`\`mermaid для графа зависимостей"
  exit 1
}

# --- Анкета (Task 3). Лимит в 100 строк на неё не распространяется: это опросник,
# а не бланк документа, и секция доступов физически не влезает в сто строк. ---
INTAKE="$TEMPLATES_DIR/intake.md"
[[ -f "$INTAKE" ]] || { echo "FAIL: шаблон не найден: $INTAKE"; exit 1; }

check_sections intake.md "$INTAKE" \
  "Как заполнять" "A. Продукт" "B. Поверхности" "C. Функционал" \
  "D. Референсы" "E. Инфраструктура и доступы" "F. Ограничения" "Покрытие"

# Секция E: все семь подсекций доступов на месте.
for sub in "E1. GitHub" "E2. Целевая площадка" "E3. База данных" "E4. Домены" \
           "E5. Сторонние API" "E6. Платежи" "E7. Аналитика"; do
  grep -qF "### $sub" "$INTAKE" || {
    echo "FAIL: intake.md — отсутствует подсекция доступов: $sub"
    exit 1
  }
done

# У каждой подсекции доступов — таблица с полным набором полей (иначе доступ
# описан словами и его нечем проверить).
ACCESS_HEADER='| есть? | что именно | имя переменной | где значение | смоук-команда | результат |'
access_tables="$(grep -cF "$ACCESS_HEADER" "$INTAKE" || true)"
(( access_tables == 7 )) || {
  echo "FAIL: intake.md — таблиц доступов $access_tables, ожидалось 7 (по подсекции на каждую)"
  exit 1
}

# Каждый вопрос в секциях A-D и F помечен [owner] или [research]: без метки
# непонятно, можно ли отдать вопрос в исследование или нужен владелец.
unlabeled="$(awk '
  /^## A\./       { inq = 1 }
  /^## E\./       { inq = 0 }
  /^## F\./       { inq = 1 }
  /^## Покрытие/  { inq = 0 }
  inq && /^- / && !/\[owner\]/ && !/\[research\]/ { print FNR ": " $0 }
' "$INTAKE")"
[[ -z "$unlabeled" ]] || {
  echo "FAIL: intake.md — вопрос без метки [owner]/[research]:"
  echo "$unlabeled"
  exit 1
}

# Правило про секреты обязано быть в шапке: анкета уходит в git.
grep -qF 'Значения секретов сюда не пишутся' "$INTAKE" || {
  echo "FAIL: intake.md — в шапке нет правила о том, что значения секретов не пишутся в анкету"
  exit 1
}

# --- Протокол сообщений владельцу (Task 5). Лимит в 100 строк не применяется:
# это протокол с четырьмя шаблонами, а не бланк одного документа. ---
TG="$TEMPLATES_DIR/telegram-protocol.md"
[[ -f "$TG" ]] || { echo "FAIL: шаблон не найден: $TG"; exit 1; }

check_sections telegram-protocol.md "$TG" \
  "Когда что отправляется" "Правила отправки" "Шаблоны" "Ответы владельца"

# Все четыре типа сообщений из спеки §11 обязаны иметь свой шаблон.
for msg in "❓ Вопрос" "✅ Блок готов" "⚠️ Алерт" "🏁 MVP готов"; do
  grep -qF "### $msg" "$TG" || {
    echo "FAIL: telegram-protocol.md — нет шаблона сообщения: $msg"
    exit 1
  }
done

# Шаблоны обязаны быть шаблонами: без плейсхолдеров это просто текст.
placeholders="$(grep -cE '\{\{[^}]+\}\}' "$TG" || true)"
(( placeholders >= 4 )) || {
  echo "FAIL: telegram-protocol.md — плейсхолдеров {{...}} найдено $placeholders, шаблоны не заполняемы"
  exit 1
}

# Два правила, без которых протокол молча ломается: батчинг и поведение при
# выключенном канале (вопрос всё равно должен попасть в questions.md).
grep -qF 'пачкой, а не по одному' "$TG" || {
  echo "FAIL: telegram-protocol.md — нет правила о батчинге вопросов"
  exit 1
}
grep -qF '`telegram: off`' "$TG" || {
  echo "FAIL: telegram-protocol.md — нет правила о поведении при выключенном канале"
  exit 1
}

# Заполненный пример анкеты не должен отставать от шаблона: forge-new будет
# ориентироваться на него как на образец, а переименованная секция превратит
# образец в неверный. Сверяем набор секций верхнего уровня с шаблоном репозитория
# (именно репозитория: TEMPLATES_DIR может быть испорченной копией из теста).
FIXTURE_INTAKE="$FORGE_HOME/test/fixtures/toy-project/intake.md"
if [[ -f "$FIXTURE_INTAKE" ]]; then
  missing="$(comm -23 \
    <(grep '^## ' "$FORGE_HOME/templates/intake.md" | sort) \
    <(grep '^## ' "$FIXTURE_INTAKE" | sort))"
  [[ -z "$missing" ]] || {
    echo "FAIL: заполненный пример анкеты отстал от шаблона — нет секций:"
    echo "$missing"
    exit 1
  }
fi

echo "PASS"
