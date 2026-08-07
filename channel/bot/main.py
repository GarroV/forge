"""Канал Forge: один процесс, который владеет ботом и отдаёт HTTP-интерфейс.

Зачем именно так. Telegram допускает **одного** слушателя на токен: два
одновременных опроса дают `409 Conflict`, причём вылетает первый, а второй
работает — и выбитый молча перестаёт получать сообщения. Пока ботом владел плагин
внутри сессии Claude Code, каждая новая сессия отбирала канал у предыдущей. Здесь
владелец один и постоянный, а сессии обращаются к нему по HTTP: сколько бы их ни
было, конфликтовать нечему.

Два интерфейса в одном процессе:
  · long polling  — забирает ответы владельца из Telegram;
  · HTTP API      — принимает от системы «отправь» и отдаёт «что пришло».

Разделение ответственности: формулировки сообщений придумывает система, канал их
не переписывает. Иначе протокол оказался бы описан в двух местах и разъехался.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from typing import Optional

from aiogram import Bot, Dispatcher, types
from aiohttp import web

import db
from core import chunk_text, is_owner, outbound_text, parse_bearer, secret_ok, validate_notify

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("forge-channel")

# Переменные, без которых канал не имеет смысла. Проверяем на старте и падаем
# внятно: контейнер, поднявшийся без секрета и молча пускающий всех, хуже
# упавшего контейнера.
REQUIRED = ("BOT_TOKEN", "DATABASE_URL", "FORGE_SECRET", "OWNER_CHAT_ID")


def read_env() -> dict:
    missing = [name for name in REQUIRED if not os.environ.get(name, "").strip()]
    if missing:
        log.error(
            "не заданы обязательные переменные: %s — заполни .env по .env.example",
            ", ".join(missing),
        )
        sys.exit(1)
    return {
        "token": os.environ["BOT_TOKEN"].strip(),
        "dsn": os.environ["DATABASE_URL"].strip(),
        "secret": os.environ["FORGE_SECRET"].strip(),
        "owner": os.environ["OWNER_CHAT_ID"].strip(),
        "port": int(os.environ.get("API_PORT", "8090")),
    }


# ─── HTTP-интерфейс для системы ────────────────────────────────────────────────


def authorized(request: web.Request) -> bool:
    supplied = parse_bearer(request.headers.get("Authorization"))
    return secret_ok(supplied, request.app["secret"])


def deny() -> web.Response:
    # Без подробностей: сообщение об ошибке не должно помогать подбирать секрет.
    return web.json_response({"error": "unauthorized"}, status=401)


async def handle_notify(request: web.Request) -> web.Response:
    if not authorized(request):
        return deny()
    try:
        payload = await request.json()
    except Exception:
        return web.json_response({"error": "тело запроса не разобрано как JSON"}, status=400)

    ok, why = validate_notify(payload)
    if not ok:
        return web.json_response({"error": why}, status=400)

    body = outbound_text(payload["kind"], payload["project"], payload["text"])
    bot: Bot = request.app["bot"]
    owner = request.app["owner"]

    message_ids = []
    try:
        for part in chunk_text(body):
            sent = await bot.send_message(chat_id=owner, text=part)
            message_ids.append(sent.message_id)
    except Exception as exc:
        # Отдаём наружу факт неудачи, а не «принято»: система обязана узнать, что
        # сообщение не дошло, и записать это у себя.
        log.exception("отправка не удалась")
        return web.json_response({"error": "telegram отказал", "detail": str(exc)}, status=502)

    entry_id = await db.log_outbound(
        request.app["pool"], payload["project"], payload["kind"], body, message_ids
    )
    return web.json_response({"ok": True, "id": entry_id, "message_ids": message_ids})


async def handle_inbox(request: web.Request) -> web.Response:
    if not authorized(request):
        return deny()
    items = await db.pending_inbound(request.app["pool"])
    return web.json_response({"pending": items})


async def handle_ack(request: web.Request) -> web.Response:
    if not authorized(request):
        return deny()
    try:
        payload = await request.json()
        ids = [int(x) for x in payload["ids"]]
    except Exception:
        return web.json_response({"error": "ожидается {\"ids\": [числа]}"}, status=400)
    touched = await db.ack_inbound(request.app["pool"], ids)
    return web.json_response({"ok": True, "acked": touched})


async def handle_health(request: web.Request) -> web.Response:
    """Состояние канала.

    Секрет здесь не требуется намеренно: это проверка живости, её дёргают
    автоматикой, и она не отдаёт ничего чувствительного. Но и врать не должна —
    статус `ok` только когда база действительно ответила.
    """
    alive = await db.db_alive(request.app["pool"])
    payload = {
        "status": "ok" if alive else "db down",
        "polling": request.app.get("polling_ok", False),
    }
    return web.json_response(payload, status=200 if alive else 503)


# ─── Приём ответов владельца из Telegram ──────────────────────────────────────


def build_dispatcher(pool, owner: str) -> Dispatcher:
    dp = Dispatcher()

    @dp.message()
    async def on_message(message: types.Message) -> None:
        chat_id = message.chat.id
        if not is_owner(chat_id, owner):
            # Чужому не отвечаем вообще: ответ подтверждает, что бот жив, и
            # приглашает продолжать. Молчание дешевле.
            log.warning("сообщение от чужого чата %s — игнорирую", chat_id)
            return

        text = (message.text or "").strip()
        if not text:
            await message.answer("Понимаю только текст.")
            return

        new_id = await db.save_inbound(pool, chat_id, message.message_id, text)
        if new_id is None:
            # Повторная доставка того же сообщения — не ошибка и не новый ответ.
            log.info("сообщение %s уже в очереди, пропускаю", message.message_id)
            return
        await message.answer("Принял. Заберу в работу, когда дойду до этого вопроса.")

    return dp


# ─── Точка входа ──────────────────────────────────────────────────────────────


async def main() -> None:
    env = read_env()
    pool = await db.connect(env["dsn"])
    bot = Bot(token=env["token"])
    dp = build_dispatcher(pool, env["owner"])

    app = web.Application()
    app["secret"] = env["secret"]
    app["owner"] = env["owner"]
    app["pool"] = pool
    app["bot"] = bot
    app["polling_ok"] = False
    app.add_routes(
        [
            web.post("/notify", handle_notify),
            web.get("/inbox", handle_inbox),
            web.post("/ack", handle_ack),
            web.get("/healthz", handle_health),
        ]
    )

    runner = web.AppRunner(app)
    await runner.setup()
    # 0.0.0.0 внутри контейнера; наружу порт публикует compose. Доступ снаружи
    # закрыт секретом, а не сетью: до контейнера дотягивается только хост.
    site = web.TCPSite(runner, host="0.0.0.0", port=env["port"])
    await site.start()
    log.info("HTTP-интерфейс слушает порт %s", env["port"])

    async def polling() -> None:
        app["polling_ok"] = True
        try:
            await dp.start_polling(bot)
        finally:
            app["polling_ok"] = False

    try:
        await polling()
    finally:
        await runner.cleanup()
        await bot.session.close()
        await pool.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        pass
