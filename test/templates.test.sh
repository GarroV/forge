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

echo "PASS"
