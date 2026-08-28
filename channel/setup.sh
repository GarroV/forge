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

# Секрет, переданный аргументом, виден в списке процессов любому пользователю
# машины: `ps` показывает argv целиком. Токен бота в адресе — это тот же секрет,
# просто внутри URL. Поэтому и адрес, и заголовок уходят в curl через --config со
# стандартного ввода: конфиг читается из потока и в argv не попадает.
curl_hidden() {
  # $1 — строки конфига (адрес, заголовки), остальное — обычные аргументы curl.
  local config="$1"; shift
  printf '%s\n' "$config" | curl -fsS --config - "$@"
}

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

bot_name="$(curl_hidden "url = \"https://api.telegram.org/bot${BOT_TOKEN}/getMe\"" --max-time 15 \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"]["username"] if d.get("ok") else "")' \
  || true)"
[[ -n "$bot_name" ]] || die "Telegram не принял токен. Проверь, что скопирован целиком, и повтори."
say "Бот принят: @${bot_name}"

# ─── Chat id мастер определяет сам ───────────────────────────────────────────
# Раньше это делалось через стороннего бота и чтение логов. Здесь — чтением
# первого же обновления: человеку остаётся написать своему боту одно слово.
# Кто угодно может найти бота по имени и написать ему первым — и стал бы
# владельцем канала, в который уходят куски спеки, решения и имена секретов.
# Поэтому принимается не первое попавшееся сообщение, а ровно одно слово, которое
# мастер сейчас придумает. И только присланное ПОСЛЕ этой секунды: Telegram
# держит непрочитанные обновления около суток, и старое сообщение постороннего
# иначе подошло бы.
PAIR_CODE="forge-$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
STARTED_AT="$(date +%s)"

# Старую очередь сначала вычитываем и выбрасываем: она не участвует в сверке.
curl_hidden "url = \"https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=-1\"" --max-time 10 >/dev/null 2>&1 || true

say ""
say "Шаг 2. Открой @${bot_name} в Telegram и отправь ему ровно это слово:"
say ""
say "           ${PAIR_CODE}"
say ""
say "       Слово одноразовое: по нему мастер отличит тебя от постороннего,"
say "       который мог написать боту раньше. Жду до двух минут…"

OWNER_CHAT_ID=""
for _ in $(seq 1 24); do
  OWNER_CHAT_ID="$(curl_hidden "url = \"https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=5\"" --max-time 10 \
    | PAIR_CODE="$PAIR_CODE" STARTED_AT="$STARTED_AT" python3 -c '
import json, os, sys
code = os.environ["PAIR_CODE"]
started = int(os.environ["STARTED_AT"])
d = json.load(sys.stdin)
for u in d.get("result", []):
    m = u.get("message") or u.get("edited_message")
    if not m:
        continue
    if int(m.get("date", 0)) < started:
        continue                      # сообщение старше мастера — чужое или прошлое
    if code not in (m.get("text") or ""):
        continue                      # не то слово — писал не тот, кому мастер его показал
    chat = m.get("chat", {}).get("id")
    if chat:
        print(chat); break
' || true)"
  [[ -n "$OWNER_CHAT_ID" ]] && break
  sleep 5
done
[[ -n "$OWNER_CHAT_ID" ]] || die "слово так и не пришло. Убедись, что писал именно @${bot_name} и именно ${PAIR_CODE}, и запусти мастер снова."
say "Ты опознан по слову — chat id определён."

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
delivered="$(curl_hidden "url = \"http://localhost:${PORT}/notify\"
header = \"Authorization: Bearer ${FORGE_SECRET}\"
header = \"content-type: application/json\"" --max-time 15 -X POST \
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
