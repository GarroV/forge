#!/usr/bin/env python3
"""Страж состава коммита: во время стройки в коммит попадает только названное.

Ставится на событие PreToolUse и делает две вещи, пока в проекте идёт стройка:
запрещает сплошной захват дерева (`git add -A`, `git add .`, `git commit -a`) и
перед обычным коммитом показывает фактический состав индекса.

Зачем механизм. Правило «коммить перечислением путей» записано и в скилле
стройки, и в брифе блок-агента — подробно, с примерами и купленными уроками. Оно
было нарушено дважды за три дня: посторонний документ уехал в коммит про защиту
от подделки запросов, а каталог Dodo IS на 8228 строк — в коммит «волна принята,
задачи закрыты». Автор коммита каждый раз не знал, что он несёт. Правило,
адресованное вниманию, проигрывает моменту, когда «надо просто закоммитить», —
поэтому здесь оно превращено в отказ.

Границы, без которых страж вреден:

1. **Вне стройки он не существует.** Нет маркера стройки в этом дереве — выход
   без единого решения. Сплошной `add` в своей работе владельца никого не
   касается, и запрещать его — значит сделать стража тем, что снимают целиком.
2. **Он не угадывает «чужое».** Отличить чужой файл от своего надёжно нельзя, а
   ложный запрет останавливает стройку на ровном месте. Поэтому запрет только на
   форму команды (она однозначна), а разбор состава — показом, не отказом.
3. **Он не ломает сессию собой.** Любая ошибка, любой мусор на входе — выход 0 и
   молчание.
"""

import importlib.util
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

# Разделители команд в одной строке: сплошной add прячется в середине цепочки
# (`cd x && git add -A && git commit -m ...`) не реже, чем стоит отдельно.
SEPARATORS = ("&&", "||", ";", "|", "\n")

# Аргументы `git add`, означающие «всё, что найдёшь», а не конкретный путь.
ADD_SWEEPING = {"-A", "--all", "--no-ignore-removal", "-u", "--update", ".", ":/", "*"}


def load_keep_building():
    """Общий источник правды о том, идёт ли стройка.

    Модуль лежит рядом, но его имя с дефисом обычным import не берётся. Своя
    копия логики маркера была бы третьим местом, где она живёт, и разошлась бы
    с остальными молча.
    """
    path = Path(__file__).resolve().parent / "keep-building.py"
    spec = importlib.util.spec_from_file_location("forge_keep_building", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_is_running(cwd: str) -> bool:
    try:
        kb = load_keep_building()
        root = kb.project_root(cwd)
        return bool(kb.read_marker(kb.marker_path(root)))
    except Exception:
        return False


def segments(command: str):
    parts = [command]
    for sep in SEPARATORS:
        parts = [chunk for part in parts for chunk in part.split(sep)]
    return [p.strip() for p in parts if p.strip()]


def sweeping_reason(segment: str):
    """Название нарушения, если сегмент сгребает дерево целиком, иначе None."""
    try:
        words = shlex.split(segment)
    except ValueError:
        words = segment.split()
    if len(words) < 2 or os.path.basename(words[0]) != "git":
        return None

    # Глобальные ключи (`git -C dir add …`) стоят до подкоманды.
    idx = 1
    while idx < len(words) and words[idx].startswith("-"):
        idx += 2 if words[idx] in ("-C", "-c", "--git-dir", "--work-tree") else 1
    if idx >= len(words):
        return None
    sub, args = words[idx], words[idx + 1:]

    if sub == "add":
        hit = [a for a in args if a in ADD_SWEEPING]
        if hit:
            return f"git add {' '.join(hit)}"
    if sub == "commit":
        for a in args:
            if a == "--all":
                return "git commit --all"
            # Короткая связка: -a, -am, -avm. `--amend` сюда не попадает — это
            # длинный ключ и правка последнего коммита, а не захват дерева.
            if a.startswith("-") and not a.startswith("--") and "a" in a[1:]:
                return f"git commit {a}"
    return None


def staged_files(cwd: str):
    try:
        out = subprocess.run(
            # quotepath=false: иначе git отдаёт кириллицу и сербские буквы
            # восьмеричными escape-последовательностями, и список путей,
            # который человек должен сверить глазами, нечитаем.
            ["git", "-C", cwd, "-c", "core.quotepath=false",
             "diff", "--cached", "--name-only"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode != 0:
            return []
        return [line for line in out.stdout.splitlines() if line.strip()]
    except Exception:
        return []


def is_commit(command: str) -> bool:
    return any(
        (lambda w: len(w) > 1 and os.path.basename(w[0]) == "git" and "commit" in w)(
            seg.split()
        )
        for seg in segments(command)
    )


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
    if not isinstance(payload, dict) or payload.get("tool_name") != "Bash":
        return 0

    command = str((payload.get("tool_input") or {}).get("command") or "")
    if not command or "git" not in command:
        return 0

    cwd = payload.get("cwd") or os.getcwd()
    if not build_is_running(cwd):
        return 0

    for segment in segments(command):
        reason = sweeping_reason(segment)
        if reason:
            deny(
                f"«{reason}» во время стройки не используется. В рабочем дереве "
                "лежит не только твоя работа: параллельная сессия владельца, "
                "данные, положенные рядом для сверки, недописанные файлы "
                "соседнего агента. Сплошной захват уносит их в твой коммит под "
                "твоим сообщением, и автор коммита не знает, что он несёт "
                "(случалось дважды: посторонний документ и каталог на 8228 "
                "строк).\n"
                "Перечисли пути: git add <файл> <файл>. Не знаешь состав — "
                "посмотри git status --short и назови нужное поимённо."
            )
            return 0

    if is_commit(command):
        files = staged_files(cwd)
        if files:
            shown = "\n".join(f"  {f}" for f in files[:20])
            more = f"\n  … и ещё {len(files) - 20}" if len(files) > 20 else ""
            inform(
                f"В индексе {len(files)} путей — они уедут в этот коммит:\n"
                f"{shown}{more}\n"
                "Сверь со списком файлов своей задачи. Лишний путь — разобраться, "
                "откуда он взялся, и убрать (git restore --staged <путь>), а не "
                "коммитить: сообщение коммита должно описывать то, что в нём "
                "лежит."
            )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Сломанный страж обязан быть незаметным, а не заклинившим: он запрещает
        # вызовы, и его отказ не должен превращаться в отказ работать.
        sys.exit(0)
