#!/usr/bin/env python3
"""Сторож непрерывности автономной стройки Forge.

Ставится глобально на событие Stop и решает ровно один вопрос: имеет ли право
сессия закончить ход прямо сейчас. Если в проекте идёт стройка и в графе есть
работа, которую можно взять, — ход не отдаётся владельцу, а диспетчер получает
указание продолжать.

Зачем это существует. Ход в Claude Code заканчивается, как только модель выдаёт
текст без вызова инструмента; управление уходит владельцу, и стройка стоит,
пока он не напишет. Раньше её непрерывность держалась на побочном эффекте
харнесса — пробуждении сессии по завершении фонового агента, — и рвалась ровно
в стыке между волнами, где живых фоновых задач нет. Написать в скилле «не
останавливайся» недостаточно: система дважды ловила себя на том, что правило,
записанное прозой, не выполняется ни разу (модель роли агента, дробление на
исполнителя). Поэтому непрерывность сделана механизмом, который не зависит от
того, что диспетчер вспомнил.

Три вещи, которые сторож обязан делать безошибочно:

1. **Молчать везде, кроме активной стройки.** Он стоит глобально и срабатывает в
   каждой сессии на каждой машине, где установлен. Нет маркера стройки — выход
   без единого решения.
2. **Не мешать, когда стройка и так продолжится.** Живой фоновый агент разбудит
   сессию сам; удерживать ход в это время — гонять диспетчера вхолостую.
3. **Отпускать, когда стройка не движется.** Удержание без прогресса жжёт лимит
   запросов и прячет остановку от владельца, вместо того чтобы её показать.

Коды возврата — контракт харнесса: `2` удерживает ход и отдаёт модели текст из
stderr, `0` отпускает. Любой сбой внутри сторожа обязан быть отпуском: сломанный
сторож не должен превращаться в заклинившую сессию.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

# Сколько ходов подряд сторож удерживает стройку, которая не сдвинулась. Движение
# — это изменение состояния проекта, а не сам факт хода: диспетчер может честно
# ответить текстом и не сделать ничего, и ловить надо именно это. Порог не ноль,
# потому что один холостой ход — норма (диспетчер осмотрелся и пошёл работать), а
# три подряд означают, что он буксует и указание продолжать ему не помогает.
MAX_IDLE_HOLDS = 3

# Потолки удержаний. Каждое удержание — это лишний ход модели с полным контекстом
# сессии, то есть настоящие деньги и настоящий лимит запросов. Поэтому у сторожа
# два независимых предела, и оба намеренно тесные: легитимной стройке они не
# мешают (между волнами хватает одного-двух удержаний), а любой сбой делают
# ограниченным по стоимости, а не бесконечным.
#
# Часовой предел ловит быстрый цикл: что-то заклинило прямо сейчас.
MAX_HOLDS_PER_HOUR = 12

# Общий предел на одну стройку ловит медленный: стройка, которая движется по
# графу, но не доходит до конца, могла бы удерживать ход сутками, обнуляя часовой
# счётчик каждый час. После этого предела сторож замолкает до следующей команды
# стройки — и это видно в маркере, а не молча.
MAX_HOLDS_TOTAL = 60

# Возраст, после которого маркер считается забытым, а не стройкой. Сессия,
# начатая месяц назад, не идёт — она брошена, и держать её наследника незачем.
MARKER_MAX_AGE = timedelta(days=7)

# Статусы задач, которые означают доступную работу. `blocked:Qnnn` ждёт владельца,
# `failed` уже видна ему в сводке, `done` закрыта — ни один из них не повод
# держать ход.
TASK_ROW = re.compile(r"^\|\s*(T\d{3})\s*\|([^|]*)\|([^|]*)\|([^|]*)\|")


def builds_dir() -> Path:
    return Path(os.path.expanduser("~")) / ".claude" / "forge" / "builds"


def project_root(start: str) -> Path:
    """Корень проекта: верхушка git-дерева, иначе сам каталог.

    Диспетчер работает из корня проекта, но может уйти в подкаталог; привязка к
    git-корню делает маркер одним и тем же в обоих случаях.
    """
    path = Path(start).resolve()
    try:
        out = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip():
            return Path(out.stdout.strip())
    except Exception:
        pass
    return path


def marker_path(root: Path) -> Path:
    digest = hashlib.sha1(str(root).encode("utf-8")).hexdigest()[:16]
    return builds_dir() / f"{digest}.json"


def read_marker(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def write_marker(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def fingerprint(root: Path) -> str:
    """Отпечаток движения стройки: по нему видно, сдвинулась ли она.

    Берутся только граф задач и журнал стройки — то, что диспетчер меняет, когда
    действительно работает: взял задачу, закрыл задачу, записал событие.

    Коммитов здесь намеренно нет, хотя соблазн велик. В проекте с забытым маркером
    идёт обычная жизнь — правки, коммиты, чужие сессии, — и если считать её
    движением стройки, счётчик буксования обнуляется на каждом коммите. Сторож
    тогда удерживает ход снова и снова, пока не упрётся в часовой потолок, а
    владелец получает сессию, которая жжёт лимит на ровном месте. Проверено
    тестом: без этой оговорки посторонний коммит возобновляет удержания.

    Времени здесь нет по той же причине: отпечаток, меняющийся сам собой, не
    отличает работу от простоя.
    """
    parts = []
    for name in ("tasks.md", "progress.md"):
        f = root / name
        try:
            parts.append(f.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            parts.append("")
    return hashlib.sha1("\x00".join(parts).encode("utf-8")).hexdigest()


def available_work(root: Path):
    """Задачи, которые можно взять прямо сейчас.

    Доступна задача `todo`, все зависимости которой `done`, и любая
    `in_progress`: во время стройки взятая и не закрытая задача без живого
    агента — это и есть остановка посреди работы.
    """
    tasks_file = root / "tasks.md"
    try:
        lines = tasks_file.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return []

    rows = {}
    for line in lines:
        m = TASK_ROW.match(line.strip())
        if not m:
            continue
        tid, block, deps, status = (x.strip() for x in m.groups())
        rows[tid] = {"id": tid, "block": block, "deps": deps, "status": status}

    done = {tid for tid, r in rows.items() if r["status"] == "done"}
    ready = []
    for r in rows.values():
        if r["status"] == "in_progress":
            ready.append(r)
            continue
        if r["status"] != "todo":
            continue
        deps = [d.strip() for d in re.split(r"[,\s]+", r["deps"]) if re.fullmatch(r"T\d{3}", d.strip())]
        if all(d in done for d in deps):
            ready.append(r)
    return ready


def has_live_background(payload: dict) -> bool:
    tasks = payload.get("background_tasks") or []
    if not isinstance(tasks, list):
        return False
    return any(
        isinstance(t, dict) and str(t.get("status", "")).lower() in ("running", "pending", "queued")
        for t in tasks
    )


def hold(reason: str) -> None:
    print(reason, file=sys.stderr)
    sys.exit(2)


def release(reason: str) -> None:
    """Отпустить ход, назвав причину.

    Причина печатается при `FORGE_HOOK_TRACE=1` и существует не ради удобства:
    без неё «сторож решил не мешать» и «сторож упал и потому не помешал»
    выглядят снаружи одинаково — как код возврата 0. Именно на этом попался
    первый вариант его тестов: испорченный сторож проходил проверку «в чужом
    каталоге молчит», хотя молчал он из-за исключения.
    """
    if os.environ.get("FORGE_HOOK_TRACE"):
        print(f"forge-hook: отпуск — {reason}", file=sys.stderr)
    sys.exit(0)


def decide(payload: dict) -> None:
    cwd = payload.get("cwd") or os.getcwd()
    root = project_root(cwd)
    path = marker_path(root)
    marker = read_marker(path)

    # Нет маркера — стройки здесь нет. Самый частый случай: обычная сессия в
    # обычном проекте, и сторож обязан быть в ней невидимым.
    if not marker:
        release("нет маркера стройки")

    try:
        started = datetime.fromisoformat(marker.get("started_at", ""))
    except Exception:
        started = datetime.now()
    if datetime.now() - started > MARKER_MAX_AGE:
        release("маркер стройки просрочен")

    # Маркер принадлежит первой сессии, которая до него дошла. Иначе окно
    # владельца, открытое в том же проекте, оказалось бы заперто чужой стройкой.
    session = str(payload.get("session_id") or "")
    owner = marker.get("session_id")
    if owner and owner != session:
        release("маркер принадлежит другой сессии")
    if not owner:
        marker["session_id"] = session
        write_marker(path, marker)

    # Живой фоновый агент разбудит сессию сам — держать её незачем и вредно.
    if has_live_background(payload):
        release("есть работающая фоновая задача — сессию разбудит её завершение")

    work = available_work(root)
    if not work:
        release("доступной работы в графе нет")

    now = datetime.now()
    bucket = now.strftime("%Y-%m-%dT%H")
    if marker.get("hour_bucket") != bucket:
        marker["hour_bucket"] = bucket
        marker["holds_this_hour"] = 0
    if marker.get("holds", 0) >= MAX_HOLDS_TOTAL:
        if not marker.get("released_reason"):
            marker["released_at"] = now.isoformat()
            marker["released_reason"] = (
                f"исчерпан общий потолок удержаний на стройку ({MAX_HOLDS_TOTAL})"
            )
            write_marker(path, marker)
        release(f"исчерпан общий потолок удержаний на стройку ({MAX_HOLDS_TOTAL})")
    if marker.get("holds_this_hour", 0) >= MAX_HOLDS_PER_HOUR:
        write_marker(path, marker)
        release(f"исчерпан потолок удержаний в час ({MAX_HOLDS_PER_HOUR})")

    current = fingerprint(root)
    if current == marker.get("last_fingerprint"):
        marker["idle_holds"] = marker.get("idle_holds", 0) + 1
    else:
        marker["idle_holds"] = 0
    marker["last_fingerprint"] = current

    # Стройка не движется дольше отведённого — отпускаем. Владелец увидит
    # остановку, а не молча крутящуюся сессию.
    if marker["idle_holds"] >= MAX_IDLE_HOLDS:
        marker["released_at"] = now.isoformat()
        marker["released_reason"] = "стройка не двигалась несколько ходов подряд"
        write_marker(path, marker)
        release("стройка не двигалась несколько ходов подряд")

    marker["holds"] = marker.get("holds", 0) + 1
    marker["holds_this_hour"] = marker.get("holds_this_hour", 0) + 1
    marker["last_hold_at"] = now.isoformat()
    # Сторож снова держит — значит прежний отпуск больше не факт. Старая причина,
    # оставленная в маркере, врала бы владельцу через сводку: он прочитал бы
    # «стройка отпущена, не двигалась», пока она идёт.
    marker["released_reason"] = None
    marker["released_at"] = None
    write_marker(path, marker)

    shown = ", ".join(f"{t['id']} ({t['block']}, {t['status']})" for t in work[:6])
    more = f" и ещё {len(work) - 6}" if len(work) > 6 else ""
    hold(
        f"Стройка не закончена: доступно задач — {len(work)}: {shown}{more}.\n"
        f"(удержание {marker['holds']} из {MAX_HOLDS_TOTAL}; каждое стоит владельцу "
        "лишнего хода, поэтому работай, а не отвечай текстом)\n"
        "Ход не отдаётся владельцу, пока есть работа, которую можно взять. "
        "Продолжай с шага 2 скилла forge-build: возьми готовые блоки и запусти их "
        "агентами, а не описывай словами, что собираешься сделать. Взял задачу — "
        "статус in_progress в tasks.md сразу.\n"
        "Если работать сейчас действительно нельзя (лимит запросов, всё ждёт "
        "ответа владельца, владелец велел остановиться) — сними стройку с "
        "непрерывного режима: python3 "
        f"{Path(__file__).resolve()} --stop {root}"
    )


def cli(args) -> int:
    """Ручные режимы: их зовёт скилл стройки, а не харнесс."""
    mode = args[0]
    target = project_root(args[1] if len(args) > 1 else os.getcwd())
    path = marker_path(target)

    if mode == "--start":
        marker = read_marker(path) or {}
        marker.update({
            "project": str(target),
            # Каждая команда стройки — новый прогон, поэтому счётчики обнуляются.
            # Иначе исчерпанный на прошлом прогоне потолок остался бы навсегда, и
            # следующая стройка молча шла бы без сторожа — то есть механизм
            # выключился бы сам, а выглядело бы это как «он есть».
            "started_at": datetime.now().isoformat(),
            "session_id": None,
            "holds": 0,
            "holds_this_hour": 0,
            "hour_bucket": None,
            "idle_holds": 0,
            "last_fingerprint": None,
            "released_reason": None,
            "released_at": None,
        })
        write_marker(path, marker)
        print(f"непрерывный режим включён для {target}\nмаркер: {path}")
        return 0

    if mode == "--stop":
        if path.exists():
            path.unlink()
            print(f"непрерывный режим выключен для {target}")
        else:
            print(f"непрерывный режим и не был включён для {target}")
        return 0

    if mode == "--marker-path":
        print(path)
        return 0

    if mode == "--off":
        # Полное выключение механизма: снимается регистрация в settings.json и
        # все маркеры стройки. Существует ради простого права владельца — иметь
        # одну команду, после которой сторож не может удержать ничего и нигде,
        # без разбирательств с JSON руками.
        removed = 0
        d = builds_dir()
        if d.exists():
            for f in d.glob("*.json"):
                f.unlink()
                removed += 1
        settings = Path(os.path.expanduser("~")) / ".claude" / "settings.json"
        unregistered = False
        try:
            data = json.loads(settings.read_text(encoding="utf-8"))
            stop = data.get("hooks", {}).get("Stop", [])
            kept = []
            for group in stop:
                hooks_left = [h for h in group.get("hooks", [])
                              if "keep-building.py" not in str(h.get("command", ""))]
                if len(hooks_left) != len(group.get("hooks", [])):
                    unregistered = True
                if hooks_left:
                    group["hooks"] = hooks_left
                    kept.append(group)
            if unregistered:
                data["hooks"]["Stop"] = kept
                if not kept:
                    data["hooks"].pop("Stop")
                settings.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        except Exception as exc:
            print(f"маркеры удалены ({removed}), но settings.json не поправлен: {exc}")
            return 1
        print(f"сторож выключен: маркеров удалено {removed}, "
              f"регистрация {'снята' if unregistered else 'и не была найдена'}")
        print("в уже открытых сессиях он перестанет вызываться только после перезапуска Claude Code")
        return 0

    if mode == "--check":
        # Файл сторожа в репозитории ничего не значит: держать ход он будет,
        # только если зарегистрирован в settings.json и сессия открыта после
        # регистрации. Диспетчер обязан уметь это проверить, а не предполагать.
        settings = Path(os.path.expanduser("~")) / ".claude" / "settings.json"
        try:
            data = json.loads(settings.read_text(encoding="utf-8"))
        except Exception:
            print("сторож НЕ зарегистрирован: ~/.claude/settings.json не читается — запусти install.sh")
            return 1
        commands = [h.get("command", "")
                    for group in data.get("hooks", {}).get("Stop", [])
                    for h in group.get("hooks", [])]
        mine = [c for c in commands if "keep-building.py" in c]
        if not mine:
            print("сторож НЕ зарегистрирован в settings.json — запусти install.sh системы")
            return 1
        if len(mine) > 1:
            print(f"сторож зарегистрирован {len(mine)} раза — это лишние удержания на каждом ходу, "
                  "почини settings.json")
            return 1
        print(f"сторож зарегистрирован: {mine[0]}\n"
              "в сессиях, открытых до регистрации, он не работает — нужен перезапуск Claude Code")
        return 0

    if mode == "--status":
        marker = read_marker(path)
        if not marker:
            print(f"непрерывный режим выключен для {target}")
            return 0
        print(json.dumps(marker, ensure_ascii=False, indent=2))
        return 0

    print(f"неизвестный режим: {mode}", file=sys.stderr)
    return 1


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1].startswith("--"):
        sys.exit(cli(sys.argv[1:]))
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            release("payload харнесса не является объектом")
        decide(payload)
    except SystemExit:
        raise
    except Exception as exc:
        # Сломанный сторож обязан быть незаметным, а не заклинившим ходом. Но
        # причина всё равно называется: сбой, выглядящий как штатное решение, —
        # это молчаливый отказ, а он дороже громкого.
        release(f"сбой сторожа: {type(exc).__name__}: {exc}")


if __name__ == "__main__":
    main()
