#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

FURCA_HOME="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="${1:-$FURCA_HOME/agents}"
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

# Правила состава коммита обязаны лежать в определении роли, а не только в брифе.
# Повод конкретный: на живом прогоне исполнителю в брифе прямым текстом запретили
# коммитить — он закоммитил, и вместе со своей работой унёс незакоммиченную правку
# блок-агента под своим сообщением. Бриф каждый раз пишет тот, кто запускает;
# определение роли агент читает при каждом запуске сам, поэтому форсер живёт здесь.
declare -a ROLE_RULES=(
  'optio.md|shared copy — do not commit|в общей копии коммит делает блок-агент'
  'optio.md|your own copy of the repository|в своей копии работа не переедет без коммита'
  'optio.md|git clean|чужие незакоммиченные правки не откатываются командами git'
  'artifex.md|by naming paths|сплошной add забирает файлы исполнителей'
)
for entry in "${ROLE_RULES[@]}"; do
  IFS='|' read -r role_file rule why <<< "$entry"
  target="$AGENTS_DIR/$role_file"
  [[ -f "$target" ]] || fail "нет определения роли $role_file, которому предписано правило: $why"
  grep -qF -- "$rule" "$target" || fail "[$role_file] потеряно правило «${rule}» ($why)"
done

# Детектор дрифта в обе стороны: скилл называет агента по имени, и если имя
# разъехалось с определением, запуск упадёт «agent type not found» уже в бою.
# Якорь — сам вызов (`subagent_type: <имя>`), а не форма имени: карта переименования
# (docs/naming.md) снимает префикс forge- с агентов по одному, и регулярка,
# завязанная на этот префикс, молча переставала бы видеть переименованных —
# ровно так же, как install.sh до задачи 0 переставал их находить.
python3 - "$FURCA_HOME" "${defined[*]}" <<'PYEOF' || exit 1
import pathlib
import re
import sys

forge_home = pathlib.Path(sys.argv[1])
defined = set(sys.argv[2].split())

pattern = re.compile(r'subagent_type:\s*"?([A-Za-z][A-Za-z0-9_-]*)"?')
referenced = set()
for base in ("skills", "templates"):
    for path in (forge_home / base).rglob("*"):
        if path.is_file():
            text = path.read_text(encoding="utf-8", errors="ignore")
            referenced.update(pattern.findall(text))

for name in sorted(referenced - defined):
    print(f"FAIL: скиллы ссылаются на агента {name}, а определения нет")
    sys.exit(1)

for name in sorted(defined - referenced):
    print(f"FAIL: агент {name} определён, но ни один скилл его не запускает — мёртвая роль")
    sys.exit(1)
PYEOF

echo "PASS"
