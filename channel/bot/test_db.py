"""Тесты работы с базой: адресация ответов владельца и миграция схемы.

Гоняются на **настоящем** Postgres, а не на подмене: проверяется здесь ровно то,
что живёт в SQL — кто какие строки видит и какие помечает. Подмена базы
проверяла бы мои представления об SQL, а не сам SQL.

Запуск: `bash test/channel-db.test.sh` из корня репозитория (он поднимает
временную базу и удаляет её после). Базы нет → прогон падает, а не пропускается:
молчаливо пропущенная проверка не отличается от пройденной.
"""

from __future__ import annotations

import os
import unittest

import asyncpg

import db

DSN = os.environ.get("FORGE_TEST_DSN", "postgresql:///forge_channel_test")

# Схема канала до появления адресации — то, что прямо сейчас крутится на
# площадке владельца. Нужна дословно: миграция обязана переварить именно её.
LEGACY_SCHEMA = """
create table if not exists outbound (
    id              bigserial primary key,
    project         text        not null,
    kind            text        not null,
    body            text        not null,
    tg_message_ids  bigint[]    not null default '{}',
    created_at      timestamptz not null default now()
);

create table if not exists inbound (
    id             bigserial primary key,
    chat_id        bigint      not null,
    tg_message_id  bigint      not null,
    body           text        not null,
    received_at    timestamptz not null default now(),
    acked_at       timestamptz,
    unique (chat_id, tg_message_id)
);
"""


class ChannelDbTestCase(unittest.IsolatedAsyncioTestCase):
    """Общая обвязка: своя схема на каждый тест, никакого общего состояния."""

    async def asyncSetUp(self):
        self.pool = await asyncpg.create_pool(DSN, min_size=1, max_size=2)
        async with self.pool.acquire() as conn:
            await conn.execute("drop table if exists inbound, outbound")
        await self.pool.close()
        self.pool = await db.connect(DSN)

    async def asyncTearDown(self):
        await self.pool.close()


class TestProjectForMessage(ChannelDbTestCase):
    async def test_finds_the_project_that_sent_the_message(self):
        await db.log_outbound(self.pool, "shop", "question", "какой порт?", [101])

        self.assertEqual(await db.project_for_message(self.pool, 101), "shop")

    async def test_finds_the_project_by_any_chunk_of_a_long_message(self):
        # Длинное сообщение уходит несколькими частями; владелец отвечает на
        # любую из них, и адрес обязан находиться по каждой.
        await db.log_outbound(self.pool, "shop", "question", "длинный вопрос", [201, 202, 203])

        for message_id in (201, 202, 203):
            with self.subTest(message_id=message_id):
                self.assertEqual(await db.project_for_message(self.pool, message_id), "shop")

    async def test_unknown_message_has_no_project(self):
        self.assertIsNone(await db.project_for_message(self.pool, 999))


class TestSaveOwnerAnswer(ChannelDbTestCase):
    """Приём ответа владельца целиком: от реплая до записи с адресом."""

    async def test_reply_to_a_question_carries_its_project(self):
        await db.log_outbound(self.pool, "shop", "question", "какой порт?", [301])

        row_id, project = await db.save_owner_answer(
            self.pool, chat_id=1, tg_message_id=40, body="вариант 2", reply_to_message_id=301
        )

        self.assertIsNotNone(row_id)
        self.assertEqual(project, "shop")

    async def test_answer_without_a_reply_has_no_address(self):
        row_id, project = await db.save_owner_answer(
            self.pool, chat_id=1, tg_message_id=41, body="решай сам", reply_to_message_id=None
        )

        self.assertIsNotNone(row_id)
        self.assertIsNone(project)

    async def test_reply_to_an_unknown_message_has_no_address(self):
        # Например, владелец ответил на сообщение из старой переписки.
        row_id, project = await db.save_owner_answer(
            self.pool, chat_id=1, tg_message_id=42, body="ага", reply_to_message_id=99999
        )

        self.assertIsNotNone(row_id)
        self.assertIsNone(project)

    async def test_redelivered_message_is_not_stored_twice(self):
        await db.save_owner_answer(
            self.pool, chat_id=1, tg_message_id=43, body="ответ", reply_to_message_id=None
        )

        row_id, _ = await db.save_owner_answer(
            self.pool, chat_id=1, tg_message_id=43, body="ответ", reply_to_message_id=None
        )

        self.assertIsNone(row_id)


class TestPendingInbound(ChannelDbTestCase):
    async def test_project_does_not_see_answers_addressed_to_another(self):
        # Ровно тот случай, ради которого всё чинилось.
        await db.save_inbound(self.pool, 1, 10, "вариант 2", project="shop")

        pending = await db.pending_inbound(self.pool, project="blog")

        self.assertEqual(pending, [])

    async def test_project_sees_its_own_answers(self):
        await db.save_inbound(self.pool, 1, 11, "вариант 2", project="shop")

        pending = await db.pending_inbound(self.pool, project="shop")

        self.assertEqual([row["text"] for row in pending], ["вариант 2"])
        self.assertEqual(pending[0]["project"], "shop")

    async def test_answer_without_an_address_is_visible_to_everyone(self):
        await db.save_inbound(self.pool, 1, 12, "решай сам", project=None)

        for project in ("shop", "blog"):
            with self.subTest(project=project):
                pending = await db.pending_inbound(self.pool, project=project)
                self.assertEqual([row["text"] for row in pending], ["решай сам"])

    async def test_caller_without_a_name_sees_everything(self):
        # Обратная совместимость: клиент, не назвавший проект, работает как раньше.
        await db.save_inbound(self.pool, 1, 13, "ответ shop", project="shop")
        await db.save_inbound(self.pool, 1, 14, "ответ blog", project="blog")

        pending = await db.pending_inbound(self.pool)

        self.assertEqual(len(pending), 2)

    async def test_acked_answers_do_not_come_back(self):
        row_id = await db.save_inbound(self.pool, 1, 15, "ответ", project="shop")
        await db.ack_inbound(self.pool, [row_id], project="shop")

        self.assertEqual(await db.pending_inbound(self.pool, project="shop"), [])


class TestAckInbound(ChannelDbTestCase):
    async def test_foreign_answer_is_rejected_and_stays_pending(self):
        # Главная защита: чужой ack не должен съедать ответ. Раньше съедал.
        row_id = await db.save_inbound(self.pool, 1, 20, "вариант 2", project="shop")

        acked, rejected = await db.ack_inbound(self.pool, [row_id], project="blog")

        self.assertEqual(acked, 0)
        self.assertEqual(rejected, [row_id])
        still_waiting = await db.pending_inbound(self.pool, project="shop")
        self.assertEqual([row["text"] for row in still_waiting], ["вариант 2"])

    async def test_own_answer_is_acked(self):
        row_id = await db.save_inbound(self.pool, 1, 21, "вариант 2", project="shop")

        acked, rejected = await db.ack_inbound(self.pool, [row_id], project="shop")

        self.assertEqual((acked, rejected), (1, []))

    async def test_mixed_batch_acks_own_and_rejects_foreign(self):
        mine = await db.save_inbound(self.pool, 1, 22, "мой", project="shop")
        foreign = await db.save_inbound(self.pool, 1, 23, "чужой", project="blog")

        acked, rejected = await db.ack_inbound(self.pool, [mine, foreign], project="shop")

        self.assertEqual(acked, 1)
        self.assertEqual(rejected, [foreign])

    async def test_unaddressed_answer_can_be_acked_by_anyone(self):
        row_id = await db.save_inbound(self.pool, 1, 24, "решай сам", project=None)

        acked, rejected = await db.ack_inbound(self.pool, [row_id], project="blog")

        self.assertEqual((acked, rejected), (1, []))

    async def test_repeated_ack_is_not_an_error(self):
        row_id = await db.save_inbound(self.pool, 1, 25, "ответ", project="shop")
        await db.ack_inbound(self.pool, [row_id], project="shop")

        acked, rejected = await db.ack_inbound(self.pool, [row_id], project="shop")

        self.assertEqual((acked, rejected), (0, []))

    async def test_caller_without_a_name_acks_everything(self):
        row_id = await db.save_inbound(self.pool, 1, 26, "ответ", project="shop")

        acked, rejected = await db.ack_inbound(self.pool, [row_id])

        self.assertEqual((acked, rejected), (1, []))


class TestMigration(unittest.IsolatedAsyncioTestCase):
    """Схема применяется к базе, которая уже работает и полна данных.

    `create table if not exists` существующую таблицу не трогает вовсе — то есть
    новая колонка сама собой не появится, и канал после обновления упал бы на
    первом же запросе. Проверяем именно переход со старой схемы на новую.
    """

    async def asyncSetUp(self):
        pool = await asyncpg.create_pool(DSN, min_size=1, max_size=2)
        async with pool.acquire() as conn:
            await conn.execute("drop table if exists inbound, outbound")
            await conn.execute(LEGACY_SCHEMA)
            await conn.execute(
                "insert into inbound (chat_id, tg_message_id, body) values (1, 30, 'старый ответ')"
            )
        await pool.close()

    async def test_existing_channel_gets_the_column_without_losing_answers(self):
        pool = await db.connect(DSN)
        try:
            pending = await db.pending_inbound(pool, project="shop")

            # Старый ответ адреса не имеет — значит виден всем, а не потерян.
            self.assertEqual([row["text"] for row in pending], ["старый ответ"])
            self.assertIsNone(pending[0]["project"])
        finally:
            await pool.close()

    async def test_schema_is_idempotent(self):
        # Контейнер перезапускается сколько угодно раз: второе применение схемы
        # не должно падать и не должно ничего терять.
        for _ in range(2):
            pool = await db.connect(DSN)
            await pool.close()

        pool = await db.connect(DSN)
        try:
            pending = await db.pending_inbound(pool)
            self.assertEqual(len(pending), 1)
        finally:
            await pool.close()


if __name__ == "__main__":
    unittest.main()
