#!/usr/bin/env bash
# Мастер подключения канала уведомлений.
#
# От человека нужен один шаг — создать бота у @BotFather и принести токен.
# Остальное мастер делает сам: генерирует секрет, САМ определяет chat id (просит
# написать боту и читает первое обновление), пишет ~/.claude/forge/channel.env с
# правами 600, поднимает контейнеры и проверяет канал сквозняком.
#
# По умолчанию канал ставится ЛОКАЛЬНО, на той же машине, где идёт стройка. Тогда
# отпадает всё, что делает инструкцию страшной: публикация порта наружу, VPN,
# обход inbound-фильтра Docker Desktop, проверка «снаружи, а не с хоста».
# Telegram опрашивается исходящими соединениями, стройка ходит по петле.
#
# Честный минус локального режима: спящая машина не получает уведомления. Ответы
# при этом не теряются — Telegram держит их около суток, и они подхватываются при
# пробуждении. Стройка в это время тоже стоит, так что рассинхронизации нет.
# Нужны уведомления при выключенной рабочей машине — ставь канал на постоянно
# включённый хост и укажи его адрес в CHANNEL_URL.
#
# Запуск: bash channel/setup.sh [--check]
#   --check — только проверить предусловия и ничего не менять.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$HOME/.claude/forge/channel.env"
COMPOSE_ENV="$HERE/.env"
PORT="${API_HOST_PORT:-8090}"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

say() { printf '%s\n' "$*"; }
die() { printf 'ОСТАНОВЛЕНО: %s\n' "$*" >&2; exit 1; }

# ─── Предусловия ─────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "нет docker — канал живёт в контейнерах"
docker info >/dev/null 2>&1 || die "docker установлен, но демон не отвечает: запусти Docker и повтори"
command -v curl >/dev/null 2>&1 || die "нет curl"
command -v python3 >/dev/null 2>&1 || die "нет python3 — им разбирается ответ Telegram"

if (( CHECK_ONLY == 1 )); then
  say "Предусловия в порядке: docker отвечает, curl и python3 на месте."
  [[ -f "$ENV_FILE" ]] && say "Настройки канала уже есть: $ENV_FILE" || say "Настроек канала пока нет — мастер их создаст."
  exit 0
fi

# ─── Существующие настройки не затираются молча ──────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
  say "Канал уже настроен: $ENV_FILE"
  read -r -p "Перенастроить заново? Старые значения будут потеряны [y/N]: " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { say "Ничего не менял."; exit 0; }
fi

# ─── Токен ───────────────────────────────────────────────────────────────────
say ""
say "Шаг 1. Создай бота: напиши @BotFather команду /newbot и следуй подсказкам."
say "       Он выдаст токен вида 1234567890:AA..."
read -r -s -p "Вставь токен (ввод не отображается): " BOT_TOKEN
say ""
[[ -n "$BOT_TOKEN" ]] || die "пустой токен"

bot_name="$(curl -fsS --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"]["username"] if d.get("ok") else "")' \
  || true)"
[[ -n "$bot_name" ]] || die "Telegram не принял токен. Проверь, что скопирован целиком, и повтори."
say "Бот принят: @${bot_name}"

# ─── Chat id мастер определяет сам ───────────────────────────────────────────
# Раньше это делалось через стороннего бота и чтение логов. Здесь — чтением
# первого же обновления: человеку остаётся написать своему боту одно слово.
say ""
say "Шаг 2. Открой @${bot_name} в Telegram и отправь ему любое сообщение."
say "       Жду до двух минут…"

OWNER_CHAT_ID=""
for _ in $(seq 1 24); do
  OWNER_CHAT_ID="$(curl -fsS --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=5" \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
for u in d.get("result", []):
    m = u.get("message") or u.get("edited_message")
    if m and m.get("chat", {}).get("id"):
        print(m["chat"]["id"]); break
' || true)"
  [[ -n "$OWNER_CHAT_ID" ]] && break
  sleep 5
done
[[ -n "$OWNER_CHAT_ID" ]] || die "сообщение так и не пришло. Убедись, что писал именно @${bot_name}, и запусти мастер снова."
say "Твой chat id определён."

# ─── Секрет и файлы настроек ─────────────────────────────────────────────────
FORGE_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
POSTGRES_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"

mkdir -p "$(dirname "$ENV_FILE")"
umask 077
cat > "$ENV_FILE" <<ENV
# Создано channel/setup.sh. Права 600: здесь секрет доступа к каналу.
CHANNEL_URL=http://localhost:${PORT}
FORGE_SECRET=${FORGE_SECRET}
ENV
chmod 600 "$ENV_FILE"

cat > "$COMPOSE_ENV" <<ENV
BOT_TOKEN=${BOT_TOKEN}
FORGE_SECRET=${FORGE_SECRET}
OWNER_CHAT_ID=${OWNER_CHAT_ID}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
API_HOST_PORT=${PORT}
ENV
chmod 600 "$COMPOSE_ENV"
say "Настройки записаны: ${ENV_FILE} и ${COMPOSE_ENV} (права 600)."

# ─── Подъём ──────────────────────────────────────────────────────────────────
say ""
say "Шаг 3. Поднимаю канал…"
docker compose -f "$HERE/docker-compose.yml" --env-file "$COMPOSE_ENV" up -d --build >/dev/null
say "Контейнеры запущены. Жду, пока канал ответит…"

healthy=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 5 "http://localhost:${PORT}/healthz" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 3
done
(( healthy == 1 )) || die "канал поднялся, но /healthz не отвечает. Логи: docker compose -f $HERE/docker-compose.yml logs bot"

# ─── Сквозная проверка: настоящее сообщение, а не «контейнер запущен» ────────
say ""
say "Шаг 4. Проверяю сквозняком — отправляю тебе сообщение."
delivered="$(curl -fsS --max-time 15 -X POST "http://localhost:${PORT}/notify" \
  -H "Authorization: Bearer ${FORGE_SECRET}" -H 'content-type: application/json' \
  -d '{"kind":"block","project":"channel","text":"Канал подключён. Это проверочное сообщение мастера настройки."}' \
  | python3 -c 'import json,sys; print("ok" if json.load(sys.stdin).get("ok") else "")' || true)"
[[ "$delivered" == "ok" ]] || die "канал поднят, но сообщение не ушло. Проверь /healthz и логи бота."

say ""
say "Готово. Проверочное сообщение должно быть у тебя в Telegram."
say "Если оно пришло — канал работает: система будет писать сюда вопросы и отчёты,"
say "а твои ответы реплаем на них будет забирать стройка."
say ""
say "Локальный режим: канал живёт на этой машине. Спящая машина уведомлений не"
say "получает — ответы полежат в Telegram и подхватятся при пробуждении, стройка"
say "в это время тоже стоит. Нужны уведомления при выключенной машине — ставь"
say "канал на постоянно включённый хост и укажи его адрес в CHANNEL_URL."
