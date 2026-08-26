#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="${1:-$FORGE_HOME/agents}"
ALLOWED_MODELS="fable opus sonnet haiku"

fail() { echo "FAIL: $1"; exit 1; }

found=0
declare -a defined=()
for agent in "$AGENTS_DIR"/*.md; do
  file="$(basename "$agent")"
  name_from_file="${file%.md}"
  found=1
  defined+=("$name_from_file")

  [[ "$(sed -n '1p' "$agent")" == "---" ]] || fail "[$file] не начинается с YAML-шапки"

  # `|| true` обязателен: без него grep без совпадения роняет скрипт через set -e
  # раньше, чем выполнится проверка ниже, и тест падает молча, без диагностики.
  declared="$(sed -n '2,20p' "$agent" | grep -m1 '^name:' | sed 's/^name: *//' | tr -d '\r' || true)"
  [[ -n "$declared" ]] || fail "[$file] в шапке нет поля name"
  [[ "$declared" == "$name_from_file" ]] || fail "[$file] name в шапке ($declared) не совпадает с именем файла"

  description="$(sed -n '2,20p' "$agent" | grep -m1 '^description:' | sed 's/^description: *//' || true)"
  [[ -n "$description" ]] || fail "[$file] в шапке нет поля description"

  # Главная проверка этого файла. Модель роли обязана лежать здесь, во frontmatter:
  # это единственное место, где она применяется сама. Пока она была написана прозой
  # в скилле, диспетчер не передал её ни разу за живой прогон — из-за этого
  # определения агентов и появились.
  model="$(sed -n '2,20p' "$agent" | grep -m1 '^model:' | sed 's/^model: *//' | tr -d '\r' || true)"
  [[ -n "$model" ]] || fail "[$file] в шапке нет поля model — роль без модели бессмысленна"
  [[ " $ALLOWED_MODELS " == *" $model "* ]] || fail "[$file] model: $model не из набора ($ALLOWED_MODELS)"

  echo "PASS: $name_from_file ($model)"
done

(( found == 1 )) || fail "не найдено ни одного определения агента в $AGENTS_DIR"

# Детектор дрифта в обе стороны: скилл называет агента по имени, и если имя
# разъехалось с определением, запуск упадёт «agent type not found» уже в бою.
# Имена самих скиллов исключаются по фактическому составу каталога, а не списком
# в тексте теста: список пришлось бы дописывать при каждом новом скилле, и первый
# же добавленный скилл ронял бы этот тест как «агент без определения».
skill_names="$(for dir in "$FORGE_HOME"/skills/*/; do basename "${dir%/}"; done | paste -sd'|' -)"

while IFS= read -r referenced; do
  [[ -z "$referenced" ]] && continue
  [[ " ${defined[*]} " == *" $referenced "* ]] || fail "скиллы ссылаются на агента $referenced, а определения нет"
done < <(grep -rohE '\bforge-(block-agent|executor|researcher|[a-z-]+)\b' "$FORGE_HOME/skills" "$FORGE_HOME/templates" \
         | grep -vE "^(${skill_names})$" | sort -u)

for name in "${defined[@]}"; do
  grep -rqE "\b$name\b" "$FORGE_HOME/skills" "$FORGE_HOME/templates" \
    || fail "агент $name определён, но ни один скилл его не запускает — мёртвая роль"
done

echo "PASS"
