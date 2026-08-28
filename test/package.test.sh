#!/usr/bin/env bash
# Согласованность пакета документов проекта: спека, план, описания блоков, граф.
#
# Зачем: эти четыре документа пишутся в одной сессии и расходятся молча. История
# `must` остаётся без блока — её просто никто не строит; блок описан, но план о нём
# не знает — диспетчер его не раздаст; секция осталась пустой — агент строит по
# догадке. Ни один из этих случаев не падает: пакет выглядит целым.
#
# Проверка целостности (state-format.test.sh) смотрит на файлы состояния — ссылки,
# циклы, этапы. Здесь — на документы, по которым строят.
#
# Аргумент — путь к проекту. Прогоняется на гейте пакета и на старте стройки.
set -euo pipefail
shopt -s nullglob

FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"

# Без аргумента прогоняются фикстуры — так же, как у проверки целостности: у самого
# репозитория системы пакета документов нет, он не Forge-проект.
if [[ $# -eq 0 ]]; then
  found=0
  for dir in "$FORGE_HOME"/test/fixtures/*/; do
    [[ -f "${dir}docs/forge/spec.md" ]] || continue
    found=1
    bash "$0" "${dir%/}"
  done
  (( found == 1 )) || { echo "FAIL: нет ни одной фикстуры с пакетом документов"; exit 1; }
  echo "PASS"
  exit 0
fi

PROJECT="$1"
[[ -d "$PROJECT" ]] || { echo "FAIL: каталог проекта не найден: $PROJECT"; exit 1; }
PROJECT="$(cd "$PROJECT" && pwd)"

FORGE_DIR="$PROJECT/docs/forge"
SPEC="$FORGE_DIR/spec.md"
PLAN="$FORGE_DIR/plan.md"
BLOCKS_DIR="$FORGE_DIR/blocks"
TASKS="$PROJECT/tasks.md"

fail() { echo "FAIL: [$PROJECT] $1"; exit 1; }
trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# 1. Состав пакета
for f in "$SPEC" "$PLAN" "$TASKS"; do
  [[ -f "$f" ]] || fail "нет документа пакета: ${f#$PROJECT/}"
done
[[ -d "$BLOCKS_DIR" ]] || fail "нет каталога описаний блоков: docs/forge/blocks/"

declared_blocks="$(for f in "$BLOCKS_DIR"/*.md; do [[ -e "$f" ]] || continue; basename "$f" .md; done | sort -u)"
[[ -n "$declared_blocks" ]] || fail "в docs/forge/blocks/ нет ни одного описания блока"

# 2. История must называет существующий блок. Связь спеки с планом должна быть
# машинной: иначе история остаётся без блока, и это замечает не проверка, а
# владелец, когда продукта нет.
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  prio="$(awk -F'|' '{print $3}' <<< "$row" | trim)"
  [[ "$prio" == "must" ]] || continue
  story="$(awk -F'|' '{print $2}' <<< "$row" | trim | cut -c1-60)"
  blk="$(awk -F'|' '{print $4}' <<< "$row" | trim)"
  [[ -n "$blk" && "$blk" != "—" ]] || fail "история must не называет блок: «${story}…»"
  grep -qxF "$blk" <<< "$declared_blocks" \
    || fail "история must ссылается на блок «${blk}», которого нет в docs/forge/blocks/: «${story}…»"
done < <(grep -E '^\|' "$SPEC" | grep -vE '^\| *(история|-{3,}) *\|' || true)

# 3. Блок описан, но план о нём не знает — диспетчер раздаёт работу по плану и
# такого блока не увидит.
while IFS= read -r blk; do
  [[ -z "$blk" ]] && continue
  grep -qF "$blk" "$PLAN" || fail "блок «${blk}» описан, но не упомянут в plan.md — диспетчер его не увидит"
done <<< "$declared_blocks"

# 4. У блока должны быть заполнены несущие разделы. Пустой контракт означает, что
# блоки строятся параллельно, не зная, чем обмениваются.
for f in "$BLOCKS_DIR"/*.md; do
  name="$(basename "$f" .md)"
  for section in "API-контракт" "Definition of Done блока"; do
    body="$(awk -v s="## $section" '
      $0 == s {found=1; next}
      found && /^## / {exit}
      found {print}
    ' "$f" | grep -vE '^\s*$|^\s*<!--|-->' || true)"
    [[ -n "$body" ]] || fail "блок «${name}»: раздел «${section}» пуст — строить по нему нечего"
  done
done

# 5. Пустая секция в спеке или плане: заголовок есть, под ним только подсказка
# шаблона. Гейт требует «пустых шаблонных секций не осталось», но до сих пор это
# никто не проверял — требование держалось на добросовестности заполняющего.
for doc in "$SPEC" "$PLAN"; do
  while IFS= read -r section; do
    body="$(awk -v s="$section" '
      $0 == s {found=1; next}
      found && /^## / {exit}
      found {print}
    ' "$doc" | grep -vE '^\s*$|^\s*<!--|-->|^\s*\|\s*-{3,}' || true)"
    [[ -n "$body" ]] || fail "${doc#$PROJECT/}: секция «${section#\#\# }» не заполнена"
  done < <(grep -E '^## ' "$doc" || true)
done

echo "PASS: пакет согласован ($PROJECT)"
