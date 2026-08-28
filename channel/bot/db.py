"""Работа с базой: журнал отправленного и очередь ответов владельца.

Две таблицы и ничего больше. Схема применяется при старте и идемпотентна —
контейнер можно перезапускать сколько угодно, миграций у одной таблицы на два
поля не завожу.
"""

from __future__ import annotations

from typing import List, Optional, Sequence, Tuple

import asyncpg

from core import visible_to

SCHEMA = """
create table if not exists outbound (
    id              bigserial primary key,
    project         text        not null,
    kind            text        not null,
    body            text        not null,
    tg_message_ids  bigint[]    not null default '{}',
    created_at      timestamptz not null default now()
);

-- Ответы владельца. Уникальность по (чат, сообщение) — защита от повторной
-- вставки: Telegram может отдать одно и то же сообщение дважды, и без этого
-- ограничения ответ прочитался бы как два разных.
create table if not exists inbound (
    id             bigserial primary key,
    chat_id        bigint      not null,
    tg_message_id  bigint      not null,
    body           text        not null,
    received_at    timestamptz not null default now(),
    acked_at       timestamptz,
    unique (chat_id, tg_message_id)
);

-- Частичный индекс: запрос «что не разобрано» — самый частый, и он не должен
-- перебирать всю переписку по мере её роста.
create index if not exists inbound_pending_idx
    on inbound (id) where acked_at is null;

-- Адрес ответа: какому проекту он предназначен. Заполняется по реплаю (см.
-- project_for_message), поэтому nullable: ответ не реплаем адреса не имеет и
-- остаётся виден всем.
--
-- Отдельным ALTER, а не колонкой в CREATE выше, потому что канал уже работает и
-- полон данных: `create table if not exists` существующую таблицу не трогает
-- вовсе, и колонка в ней не появилась бы никогда — канал упал бы после
-- обновления на первом же запросе.
alter table inbound add column if not exists project text;

-- Отметка последней удачной выборки Telegram — в базе, а не только в памяти
-- процесса. Причина: 19.08.2026 процесс завис целиком, и /healthz не отдал ни
-- 503, ни 200 — он не отдал ничего. Внутренняя проверка живости по построению не
-- может сообщить о таком отказе, а вот отметка в базе переживает зависание
-- процесса: по ней внешний наблюдатель видит, КОГДА канал перестал работать, даже
-- если спросить сам канал уже нельзя.
create table if not exists heartbeat (
    name         text        primary key,
    happened_at  timestamptz not null
);

-- Поиск проекта по id отправленного сообщения — на каждый ответ владельца.
-- Без индекса это перебор всей переписки; она растёт и не чистится.
create index if not exists outbound_message_ids_idx
    on outbound using gin (tg_message_ids);
"""


async def connect(dsn: str) -> asyncpg.Pool:
    """Пул соединений. Маленький: клиент здесь один — сама система."""
    pool = await asyncpg.create_pool(dsn, min_size=1, max_size=4)
    async with pool.acquire() as conn:
        await conn.execute(SCHEMA)
    return pool


async def log_outbound(
    pool: asyncpg.Pool, project: str, kind: str, body: str, message_ids: Sequence[int]
) -> int:
    """Пишет отправленное сообщение в журнал и возвращает его id.

    Журнал нужен не для красоты: по нему видно, что канал реально отправлял, когда
    владелец говорит «мне ничего не приходило». Без записи такой разговор
    упирается в «наверное, не дошло».
    """
    async with pool.acquire() as conn:
        return await conn.fetchval(
            "insert into outbound (project, kind, body, tg_message_ids)"
            " values ($1, $2, $3, $4) returning id",
            project,
            kind,
            body,
            list(message_ids),
        )


async def save_inbound(
    pool: asyncpg.Pool,
    chat_id: int,
    tg_message_id: int,
    body: str,
    project: Optional[str] = None,
) -> Optional[int]:
    """Кладёт ответ владельца в очередь.

    `project` — кому ответ адресован; None означает «адрес неизвестен» (владелец
    написал не реплаем). Такой ответ видят все: достаться не тому плохо, но не
    достаться никому — хуже.

    Возвращает id новой записи либо None, если такое сообщение уже лежит:
    повторная доставка от Telegram не должна плодить дубликаты ответов.
    """
    async with pool.acquire() as conn:
        return await conn.fetchval(
            "insert into inbound (chat_id, tg_message_id, body, project)"
            " values ($1, $2, $3, $4)"
            " on conflict (chat_id, tg_message_id) do nothing"
            " returning id",
            chat_id,
            tg_message_id,
            body,
            project,
        )


async def project_for_message(pool: asyncpg.Pool, tg_message_id: int) -> Optional[str]:
    """Какому проекту принадлежит отправленное сообщение с таким id.

    Так ответ владельца получает адрес: он отвечает реплаем, Telegram приносит id
    сообщения, а журнал отправленного помнит, чей это был вопрос. Длинное
    сообщение уходит несколькими частями — совпадение по любой из них годится,
    поэтому поиск идёт по массиву целиком.
    """
    async with pool.acquire() as conn:
        return await conn.fetchval(
            "select project from outbound where $1 = any(tg_message_ids)"
            " order by id desc limit 1",
            tg_message_id,
        )


async def save_owner_answer(
    pool: asyncpg.Pool,
    chat_id: int,
    tg_message_id: int,
    body: str,
    reply_to_message_id: Optional[int] = None,
) -> Tuple[Optional[int], Optional[str]]:
    """Принимает ответ владельца и определяет, кому он адресован.

    Возвращает (id записи, проект). Первое — None, если такое сообщение уже
    лежало (повторная доставка Telegram). Второе — None, если адрес неизвестен:
    ответ пришёл не реплаем или реплаем на сообщение, которого нет в журнале.

    Определяется адрес именно здесь, при приёме, а не при выдаче: id сообщения,
    на которое ответили, есть только в этот момент.
    """
    project = None
    if reply_to_message_id is not None:
        project = await project_for_message(pool, reply_to_message_id)
    row_id = await save_inbound(pool, chat_id, tg_message_id, body, project=project)
    return row_id, project


async def pending_inbound(
    pool: asyncpg.Pool, project: Optional[str] = None, limit: int = 50
) -> List[dict]:
    """Неразобранные ответы, адресованные спрашивающему, в порядке поступления.

    `project` не задан — отдаётся всё, как до появления адресации: клиент,
    который о ней не знает, продолжает работать.

    Ничего не помечает: пометка — отдельным вызовом после того, как система
    ответ действительно применила. Иначе падение между чтением и применением
    съедало бы ответ молча.
    """
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "select id, body, project, received_at from inbound"
            " where acked_at is null and ($2::text is null or project is null or project = $2)"
            " order by id limit $1",
            limit,
            project,
        )
    # Условие в запросе сужает выборку, а решение принимает то же правило, что и
    # у ack: держать адресацию в одном месте дешевле, чем ловить её расхождение
    # между двумя дорогами.
    return [
        {
            "id": r["id"],
            "text": r["body"],
            "project": r["project"],
            "received_at": r["received_at"].isoformat(),
        }
        for r in rows
        if visible_to(r["project"], project)
    ]


async def ack_inbound(
    pool: asyncpg.Pool, ids: Sequence[int], project: Optional[str] = None
) -> Tuple[int, List[int]]:
    """Помечает ответы разобранными. Возвращает (сколько помечено, чужие id).

    Пометить чужой ответ — самый дорогой способ его потерять: адресат не отличит
    «ответа ещё нет» от «ответ съеден» и будет ждать вечно. Поэтому чужие id не
    помечаются и возвращаются вызывающему списком, чтобы отказ был громким.

    Повторный вызов на уже помеченных ничего не портит и вернёт 0 — вызывающему
    не нужно помнить, ack'ал он уже или нет.
    """
    if not ids:
        return 0, []
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "select id, project from inbound where id = any($1::bigint[])", list(ids)
        )
        mine = [r["id"] for r in rows if visible_to(r["project"], project)]
        foreign = [r["id"] for r in rows if not visible_to(r["project"], project)]
        if not mine:
            return 0, foreign
        result = await conn.execute(
            "update inbound set acked_at = now()"
            " where id = any($1::bigint[]) and acked_at is null",
            mine,
        )
    # Гонка между выборкой и пометкой безопасна: чужое сюда не попадает вовсе, а
    # два одновременных ack своего разрешает `acked_at is null` — второй получит 0.
    # asyncpg отдаёт строку вида "UPDATE 3".
    touched = int(result.split()[-1]) if result else 0
    return touched, foreign


async def mark_heartbeat(pool: asyncpg.Pool, name: str = "poll") -> None:
    """Отмечает, что нечто живое произошло прямо сейчас.

    Пишется в базу намеренно: значение в памяти исчезает вместе с процессом,
    а нужно оно как раз тогда, когда процесс не отвечает.
    """
    async with pool.acquire() as conn:
        await conn.execute(
            "insert into heartbeat (name, happened_at) values ($1, now())"
            " on conflict (name) do update set happened_at = now()",
            name,
        )


async def last_heartbeat(pool: asyncpg.Pool, name: str = "poll") -> Optional[str]:
    """Когда отметка ставилась в последний раз. None — не ставилась ни разу."""
    async with pool.acquire() as conn:
        at = await conn.fetchval("select happened_at from heartbeat where name = $1", name)
    return at.isoformat() if at is not None else None


async def pending_stats(pool: asyncpg.Pool) -> Tuple[int, Optional[float]]:
    """(сколько ответов не разобрано, возраст самого старого в секундах).

    Нужно проверке живости: ответ владельца, который никто не забрал, — это
    молчаливый отказ. Владелец видит доставку, система ответа не получает, и
    заметить это можно только по числу и возрасту. Проверено: три ответа пролежали
    в очереди четыре и пять дней, и ни один участник об этом не сообщил.
    """
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "select count(*) as n, extract(epoch from now() - min(received_at)) as age"
            " from inbound where acked_at is null"
        )
    n = int(row["n"] or 0)
    age = float(row["age"]) if row["age"] is not None else None
    return n, (round(age, 1) if age is not None else None)


async def db_alive(pool: asyncpg.Pool) -> bool:
    """Отвечает ли база на самом деле — для проверки состояния канала.

    Именно запрос, а не «пул создан»: пул может существовать при мёртвой базе, и
    тогда проверка состояния врала бы.
    """
    try:
        async with pool.acquire() as conn:
            return await conn.fetchval("select 1") == 1
    except Exception:
        return False
