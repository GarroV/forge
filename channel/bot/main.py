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
from aiogram.exceptions import TelegramConflictError
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


class PollingState:
    """Факт опроса Telegram, а не намерение его начать.

    Существует из-за конкретного случая: первая версия выставляла флаг `polling`
    один раз при старте и больше не трогала. Канал двенадцать минут не получал
    сообщений (его выбил второй слушатель), а проверка живости всё это время
    отвечала `ok`. Проверка, которая не падает, когда сломано, — хуже
    отсутствующей: по ней принимают решение «всё в порядке».

    Поэтому здесь хранится время **последней удачной выборки** и число подряд
    идущих конфликтов, а не «я запустился».
    """

    #: Сколько ждать очередной удачной выборки, прежде чем счесть опрос мёртвым.
    #: Длиннее таймаута самого опроса — иначе будем ругаться на нормальное
    #: ожидание, когда владелец просто ничего не пишет.
    STALE_AFTER = 90.0

    def __init__(self) -> None:
        self.started = False
        self.last_ok: Optional[float] = None
        self.conflicts = 0
        self.last_error: Optional[str] = None

    def mark_ok(self) -> bool:
        """Удачная выборка. Возвращает True, если это выход из конфликта."""
        recovered = self.conflicts > 0
        self.started = True
        self.last_ok = asyncio.get_running_loop().time()
        self.conflicts = 0
        self.last_error = None
        return recovered

    def mark_conflict(self, message: str) -> bool:
        """Конфликт. Возвращает True только на первом — чтобы не спамить."""
        self.conflicts += 1
        self.last_error = message
        return self.conflicts == 1

    def mark_error(self, message: str) -> None:
        self.last_error = message

    def age(self) -> Optional[float]:
        if self.last_ok is None:
            return None
        return asyncio.get_running_loop().time() - self.last_ok

    def healthy(self) -> bool:
        age = self.age()
        return self.started and self.conflicts == 0 and age is not None and age <= self.STALE_AFTER


async def handle_health(request: web.Request) -> web.Response:
    """Состояние канала.

    Секрет здесь не требуется намеренно: это проверка живости, её дёргают
    автоматикой, и она не отдаёт ничего чувствительного. Но и врать не должна:
    `ok` — только когда база ответила **и** опрос действительно живой.
    """
    state: PollingState = request.app["polling"]
    alive = await db.db_alive(request.app["pool"])
    age = state.age()

    if not alive:
        status = "db down"
    elif not state.healthy():
        status = "polling down"
    else:
        status = "ok"

    payload = {
        "status": status,
        "polling": state.healthy(),
        # Факты, по которым видно, ПОЧЕМУ статус такой:
        "last_update_fetch_sec_ago": None if age is None else round(age, 1),
        "conflicts_in_a_row": state.conflicts,
        "last_error": state.last_error,
    }
    return web.json_response(payload, status=200 if status == "ok" else 503)


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


# ─── Опрос Telegram ───────────────────────────────────────────────────────────


async def poll_updates(bot: Bot, dp: Dispatcher, state: PollingState, owner: str) -> None:
    """Свой цикл опроса вместо `dp.start_polling`.

    Причина не в недоверии к aiogram: его цикл сам переживает конфликты и
    ретраит, но наружу об этом не сообщает — узнать «получаю ли я сообщения
    прямо сейчас» из него нельзя. А это ровно тот факт, из-за незнания которого
    канал двенадцать минут выглядел здоровым, будучи выбитым.

    Здесь каждая итерация явно отмечается в состоянии, а на конфликт канал
    **сам пишет владельцу**: отправка при конфликте работает, поэтому жаловаться
    он может, даже когда не может слушать.
    """
    offset: Optional[int] = None

    while True:
        try:
            updates = await bot.get_updates(
                offset=offset,
                timeout=25,
                # Нас интересуют только сообщения: реакции, редактирования и
                # прочее только заняли бы очередь.
                allowed_updates=["message"],
            )
        except TelegramConflictError as error:
            first = state.mark_conflict(str(error))
            log.error("канал выбит: %s", error)
            if first:
                # Один раз на серию, а не на каждую попытку: канал должен
                # предупредить, а не завалить владельца одинаковыми алертами.
                await notify_owner(
                    bot,
                    owner,
                    "alert",
                    "channel",
                    "Меня выбил другой слушатель бота — приём ответов не работает.\n\n"
                    "Скорее всего где-то запущен плагин Telegram в сессии Claude Code: "
                    "Telegram допускает одного слушателя на токен. Отправка при этом "
                    "работает, поэтому это сообщение и дошло.",
                )
            await asyncio.sleep(5)
            continue
        except Exception as error:  # сеть, таймаут, пятисотка Telegram
            state.mark_error(str(error))
            log.warning("выборка обновлений не удалась: %s", error)
            await asyncio.sleep(3)
            continue

        if state.mark_ok():
            log.info("опрос восстановлен")
            await notify_owner(
                bot, owner, "block", "channel",
                "Приём ответов восстановился — снова слушаю бота.",
            )

        for update in updates:
            offset = update.update_id + 1
            try:
                await dp.feed_update(bot, update)
            except Exception:
                # Падение обработчика не должно останавливать опрос: иначе одно
                # негодное сообщение выключает канал целиком.
                log.exception("обработка обновления %s не удалась", update.update_id)


async def notify_owner(bot: Bot, owner: str, kind: str, project: str, text: str) -> None:
    """Отправка владельцу изнутри канала (алерты о самом канале).

    Обычные сообщения приходят из системы через `POST /notify`; этой дорогой
    канал говорит только о себе — что его выбили или что он вернулся.
    """
    try:
        for part in chunk_text(outbound_text(kind, project, text)):
            await bot.send_message(chat_id=owner, text=part)
    except Exception:
        log.exception("не удалось отправить алерт владельцу")


# ─── Точка входа ──────────────────────────────────────────────────────────────


async def main() -> None:
    env = read_env()
    pool = await db.connect(env["dsn"])
    bot = Bot(token=env["token"])
    dp = build_dispatcher(pool, env["owner"])

    state = PollingState()

    app = web.Application()
    app["secret"] = env["secret"]
    app["owner"] = env["owner"]
    app["pool"] = pool
    app["bot"] = bot
    # Состояние опроса — отдельный объект, а не запись в приложении: aiohttp
    # ругается на изменение состояния уже запущенного приложения, и это
    # справедливо. Объект можно менять сколько угодно, приложение — нет.
    app["polling"] = state
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

    try:
        await poll_updates(bot, dp, state, env["owner"])
    finally:
        await runner.cleanup()
        await bot.session.close()
        await pool.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        pass
