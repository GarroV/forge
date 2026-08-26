"""Тесты чистой логики канала.

Гоняются без Docker и без сети: `bash test/channel.test.sh` из корня репозитория.
Проверяется в первую очередь то, что решает вопросы доступа, — потому что ошибка
здесь означает «в канал пустили чужого», а не «неаккуратно выглядит».
"""

from __future__ import annotations

import unittest

from core import (
    KINDS,
    TELEGRAM_TEXT_LIMIT,
    chunk_text,
    inbound_reply_text,
    is_owner,
    outbound_text,
    parse_ack,
    parse_bearer,
    secret_ok,
    valid_project,
    validate_notify,
    visible_to,
)


class TestParseBearer(unittest.TestCase):
    def test_takes_token_from_valid_header(self):
        self.assertEqual(parse_bearer("Bearer abc123"), "abc123")

    def test_scheme_is_case_insensitive(self):
        # RFC 7235: схема регистронезависима, и клиенты этим пользуются.
        self.assertEqual(parse_bearer("bearer abc123"), "abc123")
        self.assertEqual(parse_bearer("BEARER abc123"), "abc123")

    def test_tolerates_extra_spaces_around_token(self):
        self.assertEqual(parse_bearer("Bearer   abc123  "), "abc123")

    def test_rejects_everything_that_is_not_bearer(self):
        for header in (None, "", "abc123", "Basic abc123", "Bearer", "Bearer   "):
            with self.subTest(header=header):
                self.assertIsNone(parse_bearer(header))


class TestSecretOk(unittest.TestCase):
    def test_matching_secret_passes(self):
        self.assertTrue(secret_ok("s3cret", "s3cret"))

    def test_different_secret_fails(self):
        self.assertFalse(secret_ok("s3cret", "other"))

    def test_empty_expected_is_a_lock_not_a_pass(self):
        # Незаполненная переменная окружения не должна открывать дверь всем.
        for expected in (None, ""):
            with self.subTest(expected=expected):
                self.assertFalse(secret_ok("anything", expected))

    def test_missing_supplied_fails(self):
        for supplied in (None, ""):
            with self.subTest(supplied=supplied):
                self.assertFalse(secret_ok(supplied, "s3cret"))


class TestIsOwner(unittest.TestCase):
    def test_number_and_string_are_the_same_owner(self):
        # Telegram отдаёт число, в окружении лежит строка: 123 == "123" ложно.
        self.assertTrue(is_owner(744230399, "744230399"))
        self.assertTrue(is_owner("744230399", 744230399))

    def test_stranger_is_rejected(self):
        self.assertFalse(is_owner(999, "744230399"))

    def test_unset_owner_rejects_everyone(self):
        for owner in (None, "", "   "):
            with self.subTest(owner=owner):
                self.assertFalse(is_owner(744230399, owner))

    def test_substring_is_not_a_match(self):
        # «7442» не должен пройти как префикс владельца.
        self.assertFalse(is_owner(7442, "744230399"))


class TestValidateNotify(unittest.TestCase):
    def valid(self, **over):
        payload = {"kind": "block", "project": "forge", "text": "часть готова"}
        payload.update(over)
        return payload

    def test_accepts_valid_payload(self):
        ok, err = validate_notify(self.valid())
        self.assertTrue(ok)
        self.assertIsNone(err)

    def test_accepts_every_declared_kind(self):
        for kind in KINDS:
            with self.subTest(kind=kind):
                ok, _ = validate_notify(self.valid(kind=kind))
                self.assertTrue(ok)

    def test_rejects_unknown_kind(self):
        ok, err = validate_notify(self.valid(kind="whatever"))
        self.assertFalse(ok)
        self.assertIn("kind", err)

    def test_rejects_empty_or_blank_text(self):
        for text in ("", "   ", None, 42):
            with self.subTest(text=text):
                ok, err = validate_notify(self.valid(text=text))
                self.assertFalse(ok)
                self.assertIn("text", err)

    def test_rejects_bad_project(self):
        for project in ("", " leading", "с кириллицей", "x" * 65, None, "sla/sh"):
            with self.subTest(project=project):
                ok, err = validate_notify(self.valid(project=project))
                self.assertFalse(ok)
                self.assertIn("project", err)

    def test_rejects_non_object_body(self):
        for payload in (None, [], "строка", 7):
            with self.subTest(payload=payload):
                ok, err = validate_notify(payload)
                self.assertFalse(ok)
                self.assertIn("JSON", err)


class TestChunkText(unittest.TestCase):
    def test_short_text_stays_one_piece(self):
        self.assertEqual(chunk_text("коротко"), ["коротко"])

    def test_splits_on_line_breaks(self):
        text = "\n".join(["строка"] * 100)
        parts = chunk_text(text, limit=50)
        self.assertGreater(len(parts), 1)
        for part in parts:
            self.assertLessEqual(len(part), 50)
        # Ни одна строка не разорвана посередине.
        for part in parts:
            for line in part.split("\n"):
                self.assertEqual(line, "строка")

    def test_line_longer_than_limit_is_cut_hard(self):
        # Иначе такую строку нельзя отправить вообще.
        parts = chunk_text("x" * 25, limit=10)
        self.assertEqual(parts, ["x" * 10, "x" * 10, "x" * 5])

    def test_nothing_is_lost_or_duplicated(self):
        text = "\n".join("строка {}".format(i) for i in range(200))
        parts = chunk_text(text, limit=64)
        self.assertEqual("\n".join(parts).replace("\n", ""), text.replace("\n", ""))

    def test_default_limit_is_the_telegram_one(self):
        parts = chunk_text("y" * (TELEGRAM_TEXT_LIMIT + 10))
        self.assertEqual(len(parts), 2)
        self.assertEqual(len(parts[0]), TELEGRAM_TEXT_LIMIT)

    def test_zero_limit_is_a_programming_error(self):
        with self.assertRaises(ValueError):
            chunk_text("что-нибудь", limit=0)


class TestOutboundText(unittest.TestCase):
    def test_header_carries_mark_and_project(self):
        out = outbound_text("question", "forge", "какой порт брать?")
        self.assertTrue(out.startswith("❓"))
        self.assertIn("forge", out)
        self.assertIn("какой порт брать?", out)

    def test_every_kind_has_its_own_mark(self):
        marks = {outbound_text(k, "p", "t").split(" ")[0] for k in KINDS}
        self.assertEqual(len(marks), len(KINDS), "значки типов не должны совпадать")

    def test_text_is_passed_through_not_rewritten(self):
        # Формулировки присылает система; канал их не переписывает.
        body = "Часть api готова.\nПроверено: curl вернул 200."
        self.assertIn(body, outbound_text("block", "forge", body))

    def test_kinds_that_await_an_answer_ask_for_a_reply(self):
        # Реплай — единственный способ узнать, какому проекту адресован ответ:
        # текст ответа сам по себе про проект ничего не говорит.
        for kind in ("question", "alert"):
            with self.subTest(kind=kind):
                self.assertIn("реплаем", outbound_text(kind, "shop", "текст").lower())

    def test_kinds_that_await_nothing_carry_no_hint(self):
        for kind in ("block", "done"):
            with self.subTest(kind=kind):
                self.assertNotIn("реплаем", outbound_text(kind, "shop", "текст").lower())


class TestVisibleTo(unittest.TestCase):
    """Правило адресации ответов — то самое, ради которого всё и затевалось.

    Ровно здесь решается, съест ли одна стройка ответ, адресованный другой.
    Поэтому правило живёт одной функцией, а не переписывается в каждом запросе.
    """

    def test_answer_of_one_project_is_hidden_from_another(self):
        self.assertFalse(visible_to("shop", "blog"))

    def test_answer_of_a_project_is_visible_to_that_project(self):
        self.assertTrue(visible_to("shop", "shop"))

    def test_answer_without_an_address_is_visible_to_everyone(self):
        # Ответ не реплаем адресата не имеет. Спрятать его — значит потерять
        # совсем: деградация до сегодняшнего поведения лучше молчаливой потери.
        self.assertTrue(visible_to(None, "shop"))

    def test_caller_that_did_not_name_itself_sees_everything(self):
        # Обратная совместимость: клиент без параметра работает как раньше.
        self.assertTrue(visible_to("shop", None))
        self.assertTrue(visible_to(None, None))


class TestValidProject(unittest.TestCase):
    def test_accepts_ordinary_name(self):
        for name in ("shop", "forge", "my-app_2", "Some Project 1.0"):
            with self.subTest(name=name):
                self.assertTrue(valid_project(name))

    def test_rejects_junk(self):
        for name in (None, "", " ", 42, "-starts-with-dash", "кириллица", "x" * 65):
            with self.subTest(name=name):
                self.assertFalse(valid_project(name))


class TestParseAck(unittest.TestCase):
    def test_takes_ids_and_project(self):
        data, error = parse_ack({"ids": [1, 2], "project": "shop"})
        self.assertIsNone(error)
        self.assertEqual(data, {"ids": [1, 2], "project": "shop"})

    def test_project_is_optional(self):
        # Старый клиент шлёт только ids — он должен продолжать работать.
        data, error = parse_ack({"ids": [3]})
        self.assertIsNone(error)
        self.assertEqual(data["ids"], [3])
        self.assertIsNone(data["project"])

    def test_numeric_strings_are_accepted_as_ids(self):
        data, error = parse_ack({"ids": ["7"]})
        self.assertIsNone(error)
        self.assertEqual(data["ids"], [7])

    def test_rejects_body_without_ids(self):
        for payload in (None, {}, {"project": "shop"}, {"ids": "1,2"}, []):
            with self.subTest(payload=payload):
                data, error = parse_ack(payload)
                self.assertIsNone(data)
                self.assertTrue(error)

    def test_rejects_ids_that_are_not_numbers(self):
        data, error = parse_ack({"ids": ["abc"]})
        self.assertIsNone(data)
        self.assertTrue(error)

    def test_rejects_malformed_project(self):
        # Негодное имя проекта — отказ, а не молчаливое «считаю, что не назвался»:
        # иначе опечатка в имени тихо превращается в «вижу и помечаю всё».
        data, error = parse_ack({"ids": [1], "project": "кириллица"})
        self.assertIsNone(data)
        self.assertTrue(error)


class TestInboundReplyText(unittest.TestCase):
    def test_names_the_project_when_the_answer_is_addressed(self):
        text = inbound_reply_text("shop")
        self.assertIn("shop", text)

    def test_asks_for_a_reply_when_the_address_is_unknown(self):
        # Владелец должен узнать про промах сразу, а не через день ожидания.
        text = inbound_reply_text(None)
        self.assertIn("реплаем", text.lower())


if __name__ == "__main__":
    unittest.main()
