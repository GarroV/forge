#!/usr/bin/env bash
set -euo pipefail

# Тесты работы канала с базой: адресация ответов владельца и миграция схемы.
# В отличие от `channel.test.sh` (чистая логика, гоняется где угодно) этому нужен
# настоящий Postgres: проверяется ровно то, что живёт в SQL, — кто какие строки
# видит и какие помечает разобранными.
#
# Специально fail-closed: нет базы или нет asyncpg — прогон ПАДАЕТ и говорит, чего
# не хватает. Пропущенная проверка выглядит как пройденная, и по такому «зелёному»
# принимают решение «адресация работает», не проверив её ни разу.
#
# Переменные:
#   FORGE_TEST_PYTHON — интерпретатор с asyncpg (по умолчанию python3)
#   FORGE_TEST_DB     — имя временной базы (по умолчанию forge_channel_test)
FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
BOT_DIR="${1:-$FORGE_HOME/channel/bot}"
PYTHON="${FORGE_TEST_PYTHON:-python3}"
DB_NAME="${FORGE_TEST_DB:-forge_channel_test}"

[[ -d "$BOT_DIR" ]] || { echo "FAIL: каталог бота не найден: $BOT_DIR"; exit 1; }
for f in db.py test_db.py test_api.py; do
  [[ -f "$BOT_DIR/$f" ]] || { echo "FAIL: нет $BOT_DIR/$f"; exit 1; }
done

if ! "$PYTHON" -c 'import asyncpg, aiohttp, aiogram' >/dev/null 2>&1; then
  cat >&2 <<'MSG'
FAIL: у интерпретатора нет зависимостей канала — тесты базы гонять нечем.

  python3 -m venv /tmp/forge-channel-venv
  /tmp/forge-channel-venv/bin/pip install asyncpg aiohttp aiogram
  FORGE_TEST_PYTHON=/tmp/forge-channel-venv/bin/python bash test/channel-db.test.sh
MSG
  exit 1
fi

command -v pg_isready >/dev/null 2>&1 || { echo "FAIL: нет клиента Postgres (pg_isready) — тесты базы гонять негде"; exit 1; }
pg_isready -q || { echo "FAIL: Postgres не отвечает — подними его и повтори (brew services start postgresql@16)"; exit 1; }

# Своя база на каждый прогон: тесты дропают и пересоздают таблицы, и делать это
# в базе, где лежит переписка канала, нельзя ни при каких обстоятельствах.
dropdb --if-exists "$DB_NAME" >/dev/null 2>&1 || true
createdb "$DB_NAME" || { echo "FAIL: не удалось создать базу $DB_NAME"; exit 1; }
cleanup() { dropdb --if-exists "$DB_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Вывод в переменную, а не в конвейер: код возврата конвейера — код последней
# команды, и «PASS» печаталось бы поверх упавших тестов.
if ! output="$( cd "$BOT_DIR" && FORGE_TEST_DSN="postgresql:///$DB_NAME" "$PYTHON" -m unittest -q test_db test_api 2>&1 )"; then
  echo "$output" | tail -30
  echo "FAIL: тесты базы канала упали"
  exit 1
fi
echo "$output" | tail -3

# Пол по числу выполненных проверок — та же защита, что в channel.test.sh:
# «Ran 0 tests» тоже даёт OK и нулевой код возврата.
MIN_CHECKS=30
ran="$(printf '%s' "$output" | grep -oE '^Ran [0-9]+ test' | tail -1 | awk '{print $2}')"
[[ -n "$ran" ]] || { echo "FAIL: в выводе прогона нет строки «Ran N tests» — состав прогона неизвестен"; exit 1; }
(( ran >= MIN_CHECKS )) || {
  echo "FAIL: выполнено проверок $ran, ожидается не меньше $MIN_CHECKS — часть набора не выполнилась"
  exit 1
}

echo "PASS ($ran проверок)"
