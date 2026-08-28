"""Тесты HTTP-интерфейса канала на живой базе.

Проверяется склейка, а не логика: логика адресации живёт в `core.py` и покрыта
отдельно, здесь важно, что обработчик действительно читает имя проекта из
запроса и действительно передаёт его в базу. Ошибка ровно на этом стыке —
забытый параметр — молчалива: канал отвечает `200`, отдавая чужое.

Telegram подменён: настоящую отправку проверять здесь нечем и незачем. База —
настоящая, потому что весь смысл проверки в том, какие строки вернутся.
"""

from __future__ import annotations

import os
import unittest
from types import SimpleNamespace

import asyncpg
from aiohttp.test_utils import TestClient, TestServer

import db
import main

DSN = os.environ.get("FORGE_TEST_DSN", "postgresql:///forge_channel_test")
SECRET = "test-secret"
OWNER = "777"
AUTH = {"Authorization": "Bearer " + SECRET}


class FakeBot:
    """Достаточно для канала: отправляет и возвращает id отправленного."""

    def __init__(self):
        self.sent = []
        self._next_id = 500

    async def send_message(self, chat_id, text):
        self._next_id += 1
        self.sent.append({"chat_id": chat_id, "text": text, "message_id": self._next_id})
        return SimpleNamespace(message_id=self._next_id)


class ApiTestCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        pool = await asyncpg.create_pool(DSN, min_size=1, max_size=2)
        async with pool.acquire() as conn:
            await conn.execute("drop table if exists inbound, outbound, heartbeat")
        await pool.close()

        self.pool = await db.connect(DSN)
        self.bot = FakeBot()
        app = main.build_app(
            secret=SECRET, owner=OWNER, pool=self.pool, bot=self.bot, polling=main.PollingState()
        )
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.pool.close()


class TestInboxIsAddressed(ApiTestCase):
    async def test_project_does_not_receive_answers_of_another(self):
        await db.save_inbound(self.pool, 1, 60, "вариант 2", project="shop")

        response = await self.client.get("/inbox", params={"project": "blog"}, headers=AUTH)
        body = await response.json()

        self.assertEqual(response.status, 200)
        self.assertEqual(body["pending"], [])

    async def test_project_receives_its_own_answers(self):
        await db.save_inbound(self.pool, 1, 61, "вариант 2", project="shop")

        response = await self.client.get("/inbox", params={"project": "shop"}, headers=AUTH)
        body = await response.json()

        self.assertEqual([row["text"] for row in body["pending"]], ["вариант 2"])

    async def test_caller_without_a_project_receives_everything(self):
        await db.save_inbound(self.pool, 1, 62, "ответ shop", project="shop")
        await db.save_inbound(self.pool, 1, 63, "ответ blog", project="blog")

        response = await self.client.get("/inbox", headers=AUTH)
        body = await response.json()

        self.assertEqual(len(body["pending"]), 2)

    async def test_malformed_project_is_refused(self):
        # Опечатка в имени не должна тихо означать «отдай мне всё».
        response = await self.client.get("/inbox", params={"project": "кириллица"}, headers=AUTH)

        self.assertEqual(response.status, 400)

    async def test_secret_is_still_required(self):
        response = await self.client.get("/inbox", params={"project": "shop"})

        self.assertEqual(response.status, 401)


class TestAckProtectsForeignAnswers(ApiTestCase):
    async def test_foreign_ack_is_refused_and_answer_stays_pending(self):
        row_id = await db.save_inbound(self.pool, 1, 70, "вариант 2", project="shop")

        response = await self.client.post(
            "/ack", json={"ids": [row_id], "project": "blog"}, headers=AUTH
        )
        body = await response.json()

        self.assertEqual(response.status, 409)
        self.assertEqual(body["rejected"], [row_id])
        still_waiting = await db.pending_inbound(self.pool, project="shop")
        self.assertEqual([row["text"] for row in still_waiting], ["вариант 2"])

    async def test_own_ack_works(self):
        row_id = await db.save_inbound(self.pool, 1, 71, "вариант 2", project="shop")

        response = await self.client.post(
            "/ack", json={"ids": [row_id], "project": "shop"}, headers=AUTH
        )
        body = await response.json()

        self.assertEqual(response.status, 200)
        self.assertEqual(body["acked"], 1)

    async def test_client_without_a_project_still_acks(self):
        row_id = await db.save_inbound(self.pool, 1, 72, "ответ", project="shop")

        response = await self.client.post("/ack", json={"ids": [row_id]}, headers=AUTH)
        body = await response.json()

        self.assertEqual(response.status, 200)
        self.assertEqual(body["acked"], 1)

    async def test_malformed_body_is_refused(self):
        response = await self.client.post("/ack", json={"ids": "1,2"}, headers=AUTH)

        self.assertEqual(response.status, 400)


class TestHealthReportsWhatProcessMemoryCannot(ApiTestCase):
    """Поля, которые переживают зависание процесса и перезапуск.

    Повод: канал завис на семь часов, `/healthz` не отдал ничего, и когда именно
    он замолчал, узнали только по последней строке лога. Отметка и застой очереди
    берутся из базы, поэтому доступны и тогда, когда сам процесс не отвечает.
    """

    async def test_health_reports_queue_stall(self):
        await db.save_inbound(self.pool, 1, 70, "ответ, который никто не забрал", project=None)

        payload = await (await self.client.get("/healthz")).json()

        self.assertEqual(payload["pending_answers"], 1)
        self.assertIsNotNone(payload["oldest_pending_sec"])

    async def test_stalled_queue_does_not_change_status(self):
        # На /healthz завязан перезапуск контейнера, а неразобранный ответ
        # перезапуском не лечится: его должен забрать тот, кто спрашивал.
        await db.save_inbound(self.pool, 1, 71, "ответ", project=None)

        response = await self.client.get("/healthz")
        payload = await response.json()

        self.assertEqual(payload["status"], "polling down")  # опрос в тесте не запускался
        self.assertNotIn("pending", payload["status"])

    async def test_health_reports_last_poll_from_database(self):
        await db.mark_heartbeat(self.pool, "poll")

        payload = await (await self.client.get("/healthz")).json()

        self.assertIsNotNone(payload["last_poll_ok_at"])

    async def test_last_poll_is_absent_until_polling_happened(self):
        payload = await (await self.client.get("/healthz")).json()

        self.assertIsNone(payload["last_poll_ok_at"])


class TestFullRoundTrip(ApiTestCase):
    async def test_two_projects_do_not_take_each_others_answers(self):
        """Сценарий из-за которого чинили: две стройки, два вопроса, два ответа."""
        shop = await self.client.post(
            "/notify", json={"project": "shop", "kind": "question", "text": "какой порт?"}, headers=AUTH
        )
        blog = await self.client.post(
            "/notify", json={"project": "blog", "kind": "question", "text": "какой домен?"}, headers=AUTH
        )
        shop_message_id = (await shop.json())["message_ids"][0]
        blog_message_id = (await blog.json())["message_ids"][0]

        # Владелец отвечает реплаем на каждое сообщение.
        await db.save_owner_answer(self.pool, 1, 80, "порт 8080", reply_to_message_id=shop_message_id)
        await db.save_owner_answer(self.pool, 1, 81, "домен example.com", reply_to_message_id=blog_message_id)

        shop_pending = await (await self.client.get("/inbox", params={"project": "shop"}, headers=AUTH)).json()
        blog_pending = await (await self.client.get("/inbox", params={"project": "blog"}, headers=AUTH)).json()

        self.assertEqual([row["text"] for row in shop_pending["pending"]], ["порт 8080"])
        self.assertEqual([row["text"] for row in blog_pending["pending"]], ["домен example.com"])


if __name__ == "__main__":
    unittest.main()
