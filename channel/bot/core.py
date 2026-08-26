"""Чистая логика канала: без aiogram, aiohttp, asyncpg и вообще без сети.

Всё, что здесь лежит, проверяемо обычным `python3 -m unittest` на любой машине —
включая Mac владельца, где Python 3.9 и нет Docker. Транспорт и база живут в
соседних модулях и здесь не импортируются намеренно: тогда решения о безопасности
(кто свой, что пропускать) тестируются без поднятого стека.

Совместимость: Python 3.9+ (на сервере 3.12, локально у владельца 3.9).
"""

from __future__ import annotations

import hmac
import re
from typing import Optional, Tuple

# Типы сообщений — ровно те четыре, что описаны в протоколе системы
# (templates/telegram-protocol.md). Пятого типа не бывает: если понадобится,
# сначала правится протокол, потом здесь.
KINDS = frozenset({"question", "block", "alert", "done"})

# Жёсткий предел Telegram на одно сообщение. Не «примерно», а именно столько:
# длиннее сервер Telegram отвергает целиком.
TELEGRAM_TEXT_LIMIT = 4096

# Имя проекта попадает в текст и в базу; держим коротким и без сюрпризов.
PROJECT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$")

# Типы, после которых владелец отвечает. Только к ним добавляется подсказка про
# реплай: на «часть готова» и «готово» отвечать нечего, а лишняя строка в каждом
# сообщении быстро перестаёт читаться.
AWAITING_ANSWER = frozenset({"question", "alert"})

REPLY_HINT = "↩︎ Ответь реплаем на это сообщение — так ответ дойдёт до нужного проекта."


def parse_bearer(header: Optional[str]) -> Optional[str]:
    """Достаёт токен из заголовка `Authorization: Bearer <токен>`.

    Возвращает None на всём, что не похоже на схему Bearer, — в том числе на
    пустую строку и на «Bearer» без значения. Регистр схемы игнорируется: так
    предписывает RFC 7235, и клиенты этим пользуются.
    """
    if not header:
        return None
    parts = header.split(None, 1)
    if len(parts) != 2:
        return None
    scheme, value = parts[0], parts[1].strip()
    if scheme.lower() != "bearer" or not value:
        return None
    return value


def secret_ok(supplied: Optional[str], expected: Optional[str]) -> bool:
    """Сверяет секрет за постоянное время.

    `hmac.compare_digest` вместо `==` не ради красоты: обычное сравнение строк
    выходит на первом различии, и по времени ответа можно подбирать секрет
    посимвольно. Пустой ожидаемый секрет считается запретом, а не «пускать всех»:
    незаполненная переменная окружения не должна открывать дверь.
    """
    if not expected or not supplied:
        return False
    return hmac.compare_digest(supplied, expected)


def is_owner(chat_id: object, owner_chat_id: object) -> bool:
    """Свой ли это чат.

    Сравнение по строковому виду: Telegram отдаёт число, в переменной окружения
    лежит строка, и `123 == "123"` в Python ложно. Пустой владелец — запрет.
    """
    if owner_chat_id is None or str(owner_chat_id).strip() == "":
        return False
    return str(chat_id).strip() == str(owner_chat_id).strip()


def valid_project(value: object) -> bool:
    """Годится ли строка как имя проекта.

    Имя попадает и в текст сообщения, и в адресацию ответов, поэтому проверка
    одна на всех входах: `notify`, `ack` и параметр `inbox`. Разъехавшиеся
    правила означали бы, что проект называет себя по-разному в разных вызовах и
    перестаёт узнавать собственные ответы.
    """
    return isinstance(value, str) and bool(PROJECT_RE.match(value))


def visible_to(row_project: Optional[str], asking_project: Optional[str]) -> bool:
    """Виден ли ответ владельца тому, кто сейчас спрашивает.

    Ради этого правила и заведена адресация. Раньше очередь ответов была общей:
    диспетчер, спросивший первым, забирал чужой ответ, применял его к своим
    вопросам и помечал разобранным — второй проект ждал вечно, а первый ехал не
    туда. Отказ был молчаливым с обеих сторон.

    Два послабления сделаны намеренно:
      · ответ **без адреса** (владелец написал не реплаем) виден всем — иначе он
        не достался бы никому, а это хуже, чем достаться не тому;
      · спрашивающий **без имени** видит всё — старый клиент продолжает работать
        как раньше.
    """
    if asking_project is None or row_project is None:
        return True
    return row_project == asking_project


def parse_ack(payload: object) -> Tuple[Optional[dict], Optional[str]]:
    """Разбирает тело запроса на пометку ответов разобранными.

    Возвращает (данные, причина отказа) — ровно одно из двух не None. Имя
    проекта необязательно, но если названо негодно — это отказ, а не «считаю,
    что не назвался»: опечатка в имени иначе тихо превращалась бы в право
    помечать чужое.
    """
    if not isinstance(payload, dict):
        return None, "тело запроса должно быть объектом JSON"

    raw_ids = payload.get("ids")
    if not isinstance(raw_ids, list):
        return None, 'ожидается {"ids": [числа]}'

    ids = []
    for item in raw_ids:
        # bool — подкласс int, и `int(True)` дал бы идентификатор 1 на ровном месте.
        if isinstance(item, bool) or not isinstance(item, (int, str)):
            return None, "идентификаторы должны быть числами"
        try:
            ids.append(int(item))
        except ValueError:
            return None, "идентификаторы должны быть числами"

    project = payload.get("project")
    if project is not None and not valid_project(project):
        return None, "поле project: латиница, цифры, пробел, точка, дефис, подчёркивание, до 64 символов"

    return {"ids": ids, "project": project}, None


def validate_notify(payload: object) -> Tuple[bool, Optional[str]]:
    """Проверяет тело запроса на отправку сообщения.

    Возвращает (ок, причина отказа). Причина — для владельца в ответе API, поэтому
    человекочитаемая и без внутренних деталей.
    """
    if not isinstance(payload, dict):
        return False, "тело запроса должно быть объектом JSON"

    kind = payload.get("kind")
    if kind not in KINDS:
        return False, "поле kind должно быть одним из: " + ", ".join(sorted(KINDS))

    text = payload.get("text")
    if not isinstance(text, str) or not text.strip():
        return False, "поле text обязательно и не может быть пустым"

    if not valid_project(payload.get("project")):
        return False, "поле project обязательно: латиница, цифры, пробел, точка, дефис, подчёркивание, до 64 символов"

    return True, None


def chunk_text(text: str, limit: int = TELEGRAM_TEXT_LIMIT) -> list:
    """Режет длинный текст на части, влезающие в одно сообщение Telegram.

    Режем по переносам строк, а не по символам: сообщения канала — это списки
    задач и вопросов, и разрыв посреди строки делает их неразборчивыми. Строка,
    которая сама длиннее предела, режется жёстко — иначе её не отправить вовсе.
    """
    if limit <= 0:
        raise ValueError("limit должен быть положительным")
    if len(text) <= limit:
        return [text]

    chunks = []
    current = ""
    for line in text.split("\n"):
        while len(line) > limit:
            if current:
                chunks.append(current)
                current = ""
            chunks.append(line[:limit])
            line = line[limit:]
        candidate = line if not current else current + "\n" + line
        if len(candidate) <= limit:
            current = candidate
        else:
            chunks.append(current)
            current = line
    if current:
        chunks.append(current)
    return chunks


def outbound_text(kind: str, project: str, text: str) -> str:
    """Собирает итоговый текст сообщения владельцу.

    Шапка одинаковая для всех типов: значок, назначение и имя проекта. Значки —
    те же, что в протоколе системы, чтобы сообщение из канала и описание в
    документах читались одинаково.

    Формулировки самого сообщения канал НЕ придумывает: их присылает система.
    Иначе протокол оказался бы описан в двух местах и разъехался.
    """
    marks = {
        "question": "❓ Нужно решение",
        "block": "✅ Часть готова",
        "alert": "⚠️ Внимание",
        "done": "🏁 Готово",
    }
    head = marks.get(kind, kind)
    body = "{} · {}\n\n{}".format(head, project, text.strip())
    if kind in AWAITING_ANSWER:
        # Без реплая канал не знает, какому проекту адресован ответ: текст
        # ответа про проект ничего не говорит. Подсказка стоит одной строки и
        # экономит владельцу разбор «почему стройка не увидела мой ответ».
        body += "\n\n" + REPLY_HINT
    return body


def inbound_reply_text(project: Optional[str]) -> str:
    """Что канал отвечает владельцу, приняв сообщение.

    Подтверждение называет проект, если ответ адресован реплаем, и честно
    предупреждает, когда адресата нет: молчаливое «Принял» на безадресный ответ
    оставляло владельца в уверенности, что ответ ушёл по назначению.
    """
    if project:
        return "Принял — проект {}. Заберу в работу, когда дойду до этого вопроса.".format(project)
    return (
        "Принял. Но к какому проекту это относится, я не вижу — ответ уйдёт в общую "
        "очередь, и его может забрать любая идущая стройка. Если их сейчас больше "
        "одной, ответь реплаем на сообщение нужной."
    )
