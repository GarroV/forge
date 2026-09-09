#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
FURCA_HOME="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="${HOME}/.claude/skills"
AGENTS_DIR="${HOME}/.claude/agents"
PROFILE_DIR="${HOME}/.claude/furca"
SETTINGS="${HOME}/.claude/settings.json"
mkdir -p "$SKILLS_DIR" "$AGENTS_DIR" "$PROFILE_DIR"
# Протухшие симлинки снимаем до установки новых: карта переименования
# (docs/naming.md) снимает префикс forge- со скиллов и агентов по одному, и без
# этой уборки после каждого шага в реестре остаются рядом старое (битое) имя и
# новое — модель видит оба и путается, каким пользоваться. Трогаем только свои
# симлинки: цель должна лежать под $FURCA_HOME, иначе это чужой набор
# (ecc, vercel, superpowers и т. п.) в этом же плоском реестре, и решать за него
# не наше дело.
for link in "$SKILLS_DIR"/* "$AGENTS_DIR"/*; do
  [[ -L "$link" ]] || continue
  target="$(readlink "$link")"
  [[ "$target" == "$FURCA_HOME"/* ]] || continue
  [[ -e "$target" ]] && continue
  rm -f "$link"
  echo "$(basename "$link") -> удалён протухший симлинк"
done
# Дискавери — по всем прямым подкаталогам skills/ и всем *.md в agents/, а не по
# префиксу forge-: набор имён FURCA (docs/naming.md) префикса не разделяет.
for skill in "$FURCA_HOME"/skills/*/; do
  name="$(basename "$skill")"
  ln -sfn "${skill%/}" "$SKILLS_DIR/$name"
  echo "skill: $name -> linked"
done
# Роли агентов ставятся определениями, а не памяткой в скилле: модель зашита
# во frontmatter, поэтому диспетчер не может забыть её передать.
for agent in "$FURCA_HOME"/agents/*.md; do
  name="$(basename "$agent")"
  ln -sfn "$agent" "$AGENTS_DIR/$name"
  echo "agent: ${name%.md} -> linked"
done
# Сторож непрерывности стройки ставится установщиком, а не руками: без него
# диспетчер отдаёт ход владельцу в стыке между волнами, и стройка стоит до
# следующего сообщения. Регистрация идемпотентна и не трогает чужие хуки —
# settings.json принадлежит владельцу, а не системе.
python3 - "$FURCA_HOME" "$SETTINGS" <<'HOOKREG'
import json, pathlib, shutil, sys

furca_home, settings_path = sys.argv[1], pathlib.Path(sys.argv[2])

# Механизмы стройки, которые обязаны стоять в харнессе, а не в чьей-то памяти.
# Сторож непрерывности не даёт ходу закончиться посреди стройки; страж состава
# коммита не даёт сплошному `git add` унести в коммит чужую работу из общего
# дерева; страж изображений не пускает скриншот в контекст дорогой роли, оставляя
# сверку экрана роли norma. Все трое нарушались, пока были
# правилами в тексте: замер одной реальной стройки дал 40 картинок, удержание
# которых стоило 20% расхода блок-агентов.
# (событие, файл, таймаут, подпись, матчер инструментов)
HOOKS = [
    ("Stop", "keep-building.py", 20,
     "Проверяю, осталась ли работа по стройке", None),
    ("PreToolUse", "guard-commit-scope.py", 10,
     "Смотрю, что уедет в коммит", "Bash"),
    ("PreToolUse", "guard-wave-width.py", 10,
     "Считаю, сколько блоков потянет остаток лимита", "Agent|Task"),
    ("PreToolUse", "guard-image-reads.py", 10,
     "Проверяю, кому достанется картинка", "Read"),
]

settings = {}
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except Exception:
        # Испорченный settings.json чинит владелец, а не установщик: перезаписать
        # его своей версией значит молча снести все его настройки.
        print("hook: settings.json не читается как JSON — хуки НЕ зарегистрированы, почини файл и повтори")
        raise SystemExit(0)

hooks = settings.setdefault("hooks", {})

for event, filename, timeout, status, matcher in HOOKS:
    path = f"{furca_home}/hooks/{filename}"
    # Команда обязана переживать исчезновение файла хука. Её код возврата уходит
    # харнессу как решение, и `python3` на несуществующем файле отдаёт 2: на Stop
    # это «ход владельцу не отдавать», на PreToolUse — «запретить вызов», то есть
    # запрет всех инструментов разом, чинить который изнутри сессии уже нечем.
    # Хватает переезда репозитория, чтобы это накрыло все сессии машины.
    command = f"[ -f {path} ] || exit 0; python3 {path}"

    groups = hooks.setdefault(event, [])
    # Свои записи узнаём по имени файла, а не по полной команде: путь меняется при
    # переезде репозитория, и сравнение по нему плодило бы дубли.
    ours = [g for g in groups
            if any(filename in str(h.get("command", "")) for h in g.get("hooks", []))]
    if ours:
        for group in ours:
            for h in group["hooks"]:
                if filename in str(h.get("command", "")):
                    h["command"] = command
        action = "обновлён"
    else:
        entry = {"type": "command", "command": command, "timeout": timeout,
                 "statusMessage": status}
        group = {"hooks": [entry]}
        if matcher:
            group["matcher"] = matcher
        groups.append(group)
        action = "зарегистрирован"
    print(f"hook: {filename} {action} ({event})")

settings_path.parent.mkdir(parents=True, exist_ok=True)
if settings_path.exists():
    shutil.copy(settings_path, str(settings_path) + ".furca-backup")
settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8")
HOOKREG

# Профиль мог остаться на прежнем месте (~/.claude/forge/profile.md) с личными
# настройками владельца — установка обязана перенести именно его, а не
# создать пустой профиль с нуля. Остальное в ~/.claude/forge/ (канал, личные
# находки, свои скрипты) эта задача не трогает: секрет канала переезжает
# отдельно, более осторожным шагом, синхронно с живым хостом.
OLD_PROFILE="${HOME}/.claude/forge/profile.md"
if [[ -f "$PROFILE_DIR/profile.md" ]]; then
  echo "profile: exists, skipped"
elif [[ -f "$OLD_PROFILE" ]]; then
  mv "$OLD_PROFILE" "$PROFILE_DIR/profile.md"
  echo "profile: перенесён из ~/.claude/forge/profile.md"
else
  template="$(cat "$FURCA_HOME/profile.example.md")"
  printf '%s\n' "${template//__FURCA_HOME__/$FURCA_HOME}" > "$PROFILE_DIR/profile.md"
  echo "profile: created"
fi
# Реестр агентов в уже открытой сессии обновляется, но с задержкой: сразу после
# появления файла запуск падает «agent type not found», через некоторое время тот же
# агент доступен без перезапуска. Проверено дважды 07.08.2026 — сначала падением на
# только что созданном определении, потом его же успешным запуском в той же сессии.
# Поэтому здесь не «перезапусти обязательно», а «повтори, потом перезапусти»:
# обещать перезапуск как единственный путь — значит гонять человека зря.
echo "Новые определения агентов в уже открытых сессиях подхватываются с задержкой."
echo "Упало «agent type not found» — повтори чуть позже; не помогло — перезапусти Claude Code."
# Хуки харнесс снимает снимком при старте сессии, поэтому обещать здесь «уже
# работает» нельзя: в открытом окне сторож начнёт держать стройку только после
# перезапуска, и владелец должен узнать это здесь, а не по стоящей стройке.
echo "Сторож непрерывности стройки включится в уже открытых сессиях только после перезапуска Claude Code."
