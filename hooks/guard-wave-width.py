#!/usr/bin/env python3
"""Ограничитель ширины волны: чем меньше лимита, тем уже волна блок-агентов.

Ставится на событие PreToolUse и смотрит запуски агентов, пока в проекте идёт
стройка. Вдали от лимита не вмешивается вовсе; ближе — предупреждает и называет
разумную ширину; на исходе окна разрешает волне ровно одного агента.

Зачем механизм. Диспетчер выдаёт каждому блоку изолированный стенд и свои порты,
то есть о конфликтах ресурсов машины он думает. Общий лимит сессии ресурсом не
выглядит: он невидим изнутри разговора, и о нём не думает никто. На живом
прогоне четыре блок-агента одной волны оборвались одновременно с «session
limit» — каждый в шаге от сдачи, ни один не успел проверить работу. Четверо
жгут окно вчетверо быстрее одного и умирают все разом, а не по очереди; при
этом теряется именно проверка, потому что она делается последней, — и блок
оказывается «не принят», даже когда код готов.

Почему ограничитель скупой. Он запрещает запуск работы, а ложный запрет
останавливает стройку целиком. Поэтому: до 70% выбранного окна его не
существует; между 70% и 85% он только говорит; и лишь ближе к концу переходит к
отказу — и то оставляя волне одного агента, потому что останавливать стройку
целиком это дело сторожа непрерывности, а не его.
"""

import importlib.util
import json
import os
import sys
import time
from pathlib import Path

# Ниже этого расхода ограничителя не существует.
WARN_PCT = 70

# Волна, запущенная в пределах этого окна, считается одной волной: агенты
# запускаются подряд, а живут десятками минут.
WAVE_WINDOW_SEC = 600

# Инструменты, которыми запускают агентов. Имя зависит от харнесса, поэтому их
# два: система ставится и там, где инструмент называется иначе.
AGENT_TOOLS = ("Agent", "Task")


def load_keep_building():
    path = Path(__file__).resolve().parent / "keep-building.py"
    spec = importlib.util.spec_from_file_location("forge_keep_building", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def recommended_width(pct: int) -> int:
    """Сколько блоков разумно держать в волне при таком расходе.

    Числа грубые намеренно: точной модели расхода нет и быть не может — она
    зависит от размера блоков и модели агентов. Смысл не в точности, а в том,
    чтобы ширина падала раньше, чем окно кончится.
    """
    if pct >= 85:
        return 1
    if pct >= WARN_PCT:
        return 2
    if pct >= 50:
        return 3
    return 4


def fresh_launches(marker: dict, now: float):
    raw = marker.get("wave_launches")
    if not isinstance(raw, list):
        return []
    return [t for t in raw
            if isinstance(t, (int, float)) and now - t < WAVE_WINDOW_SEC]


def deny(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))


def inform(context: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "additionalContext": context,
        }
    }, ensure_ascii=False))


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") not in AGENT_TOOLS:
        return 0

    try:
        kb = load_keep_building()
        root = kb.project_root(payload.get("cwd") or os.getcwd())
        path = kb.marker_path(root)
        marker = kb.read_marker(path)
    except Exception:
        return 0
    if not marker:
        return 0

    worst = None
    try:
        worst = kb.usage_worst()
    except Exception:
        worst = None
    if not worst:
        return 0

    name, pct = worst
    if pct < WARN_PCT:
        return 0

    now = time.time()
    launches = fresh_launches(marker, now)
    width = recommended_width(pct)

    if len(launches) >= width:
        deny(
            f"Лимит подписки: окно {name} израсходовано на {pct}%. При таком "
            f"остатке волна — не больше {width} блок(а/ов), а в этой уже "
            f"{len(launches)} за последние {WAVE_WINDOW_SEC // 60} минут.\n"
            "Дождись, пока запущенные сдадут блоки, прими их и запускай "
            "следующий. Волна из нескольких агентов сожжёт окно быстрее и "
            "оборвётся вся разом — причём на проверке, которую каждый делает "
            "последней, так что не примется ни один блок, даже с готовым кодом."
        )
        return 0

    marker["wave_launches"] = launches + [now]
    try:
        kb.write_marker(path, marker)
    except Exception:
        pass

    inform(
        f"Лимит подписки: окно {name} израсходовано на {pct}%. Запуск разрешён, "
        f"но волну держи не шире {width} блок(а/ов) — сейчас в ней "
        f"{len(launches) + 1}.\n"
        "Запиши остаток в журнал стройки вместе с составом волны: если она "
        "оборвётся, причина должна быть видна в файле состояния, а не только в "
        "уведомлении, которое исчезнет вместе с сессией. И потребуй от агентов "
        "коммита после каждой задачи — тогда обрыв стоит одной задачи, а не "
        "всего блока."
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Сломанный ограничитель обязан быть незаметным: он запрещает запуск
        # работы, и его отказ не должен превращаться в отказ строить.
        sys.exit(0)
