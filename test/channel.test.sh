#!/usr/bin/env bash
set -euo pipefail

# Тесты чистой логики канала. Гоняются без Docker и без сети: всё, что требует
# aiogram/asyncpg, живёт в других модулях и в core.py не импортируется намеренно —
# тогда решения о доступе проверяются без поднятого стека.
FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
BOT_DIR="${1:-$FORGE_HOME/channel/bot}"

[[ -d "$BOT_DIR" ]] || { echo "FAIL: каталог бота не найден: $BOT_DIR"; exit 1; }
for f in core.py test_core.py; do
  [[ -f "$BOT_DIR/$f" ]] || { echo "FAIL: нет $BOT_DIR/$f"; exit 1; }
done

# core.py обязан оставаться свободным от внешних зависимостей: как только в него
# попадёт aiogram или asyncpg, эти тесты перестанут гоняться на машине без Docker,
# и проверки доступа станет нечем проверить.
forbidden="$(grep -nE '^\s*(import|from)\s+(aiogram|aiohttp|asyncpg)' "$BOT_DIR/core.py" || true)"
[[ -z "$forbidden" ]] || {
  echo "FAIL: core.py потянул внешнюю зависимость — тесты логики перестанут работать без Docker:"
  echo "$forbidden"
  exit 1
}

# Запуск из каталога бота: core.py импортируется напрямую, без установки пакета.
# Вывод в переменную, а НЕ в конвейер: код возврата конвейера — это код последней
# команды (`tail`), то есть всегда 0, и «PASS» печаталось бы поверх упавших тестов.
if ! output="$( cd "$BOT_DIR" && python3 -m unittest -q test_core 2>&1 )"; then
  echo "$output" | tail -20
  echo "FAIL: тесты логики канала упали"
  exit 1
fi
echo "$output" | tail -3

echo "PASS"
