#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
# По умолчанию проверяются реальные скиллы репо; аргумент — каталог с копией
# (используется негативными прогонами на испорченных копиях).
SKILLS_DIR="${1:-$FORGE_HOME/skills}"
MAX_DESCRIPTION=1024

fail() { echo "FAIL: $1"; exit 1; }

found=0
for dir in "$SKILLS_DIR"/*/; do
  name="$(basename "${dir%/}")"
  skill="${dir}SKILL.md"
  [[ -f "$skill" ]] || fail "[$name] нет файла SKILL.md"
  found=1

  # 1. Шапка: name обязателен и обязан совпадать с именем каталога — иначе
  # харнесс и install.sh расходятся в том, как называется команда.
  [[ "$(sed -n '1p' "$skill")" == "---" ]] || fail "[$name] SKILL.md не начинается с YAML-шапки"
  # `|| true` обязателен: без него grep без совпадения роняет скрипт через set -e
  # раньше, чем выполнится проверка ниже, и тест падает молча, без диагностики.
  declared="$(sed -n '2,20p' "$skill" | grep -m1 '^name:' | sed 's/^name: *//' | tr -d '\r' || true)"
  [[ -n "$declared" ]] || fail "[$name] в шапке нет поля name"
  [[ "$declared" == "$name" ]] || fail "[$name] name в шапке ($declared) не совпадает с именем каталога"

  # 2. Описание: по нему модель решает, вызывать скилл или нет. Пустое описание
  # означает, что скилл не найдётся никогда.
  description="$(sed -n '2,20p' "$skill" | grep -m1 '^description:' | sed 's/^description: *//' || true)"
  [[ -n "$description" ]] || fail "[$name] в шапке нет поля description"
  desc_len="${#description}"
  (( desc_len <= MAX_DESCRIPTION )) || fail "[$name] description длиной $desc_len символов, лимит $MAX_DESCRIPTION"

  # 3. Все пути к шаблонам и тестам, которые скилл называет, обязаны
  # существовать. Это защита от молчаливого дрифта: переименовали шаблон —
  # скилл продолжает ссылаться на старое имя и ломается только в бою.
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    target="$FORGE_HOME/$ref"
    if [[ "$ref" == */ ]]; then
      [[ -d "$target" ]] || fail "[$name] ссылается на несуществующий каталог: $ref"
    else
      [[ -e "$target" ]] || fail "[$name] ссылается на несуществующий файл: $ref"
    fi
  done < <(grep -ohE '\b(templates|test)/[A-Za-z0-9_./-]*' "$skill" | sed 's/\.$//' | sort -u)

  echo "PASS: $name"
done

(( found == 1 )) || fail "не найдено ни одного скилла в $SKILLS_DIR"

# 4. Чистота ядра: скиллы и шаблоны обязаны работать у любого человека, а не
# только у владельца этой машины. Поэтому в них не должно быть ни зашитого адреса
# конкретного репозитория (`--repo владелец/имя`), ни абсолютных путей в домашний
# каталог. Имя владельца в проверке намеренно не упоминается — иначе оно само
# оказалось бы прописано в ядре. Адрес репозитория системы определяется из remote,
# личные пути живут в профиле пользователя.
for scope in "$SKILLS_DIR" "$FORGE_HOME/templates"; do
  [[ -d "$scope" ]] || continue

  hardcoded_repo="$(grep -rnE -- '--repo[= ]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$scope" || true)"
  [[ -z "$hardcoded_repo" ]] || {
    echo "FAIL: зашит конкретный репозиторий (адрес определяется из remote, а не пишется в ядро):"
    echo "$hardcoded_repo"
    exit 1
  }

  home_path="$(grep -rnE -- '(/Users/|/home/)[A-Za-z0-9]' "$scope" || true)"
  [[ -z "$home_path" ]] || {
    echo "FAIL: абсолютный путь в домашний каталог (личное живёт в профиле пользователя):"
    echo "$home_path"
    exit 1
  }
done

echo "PASS"
