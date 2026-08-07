"""Работа с базой: журнал отправленного и очередь ответов владельца.

Две таблицы и ничего больше. Схема применяется при старте и идемпотентна —
контейнер можно перезапускать сколько угодно, миграций у одной таблицы на два
поля не завожу.
"""

from __future__ import annotations

from typing import List, Optional, Sequence

import asyncpg

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
    pool: asyncpg.Pool, chat_id: int, tg_message_id: int, body: str
) -> Optional[int]:
    """Кладёт ответ владельца в очередь.

    Возвращает id новой записи либо None, если такое сообщение уже лежит:
    повторная доставка от Telegram не должна плодить дубликаты ответов.
    """
    async with pool.acquire() as conn:
        return await conn.fetchval(
            "insert into inbound (chat_id, tg_message_id, body)"
            " values ($1, $2, $3)"
            " on conflict (chat_id, tg_message_id) do nothing"
            " returning id",
            chat_id,
            tg_message_id,
            body,
        )


async def pending_inbound(pool: asyncpg.Pool, limit: int = 50) -> List[dict]:
    """Неразобранные ответы, в порядке поступления.

    Ничего не помечает: пометка — отдельным вызовом после того, как система
    ответ действительно применила. Иначе падение между чтением и применением
    съедало бы ответ молча.
    """
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "select id, body, received_at from inbound"
            " where acked_at is null order by id limit $1",
            limit,
        )
    return [
        {
            "id": r["id"],
            "text": r["body"],
            "received_at": r["received_at"].isoformat(),
        }
        for r in rows
    ]


async def ack_inbound(pool: asyncpg.Pool, ids: Sequence[int]) -> int:
    """Помечает ответы разобранными. Возвращает, сколько записей затронуто.

    Повторный вызов на уже помеченных ничего не портит и вернёт 0 — вызывающему
    не нужно помнить, ack'ал он уже или нет.
    """
    if not ids:
        return 0
    async with pool.acquire() as conn:
        result = await conn.execute(
            "update inbound set acked_at = now()"
            " where id = any($1::bigint[]) and acked_at is null",
            list(ids),
        )
    # asyncpg отдаёт строку вида "UPDATE 3".
    return int(result.split()[-1]) if result else 0


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
