#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
FORGE_HOME="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="${HOME}/.claude/skills"
AGENTS_DIR="${HOME}/.claude/agents"
PROFILE_DIR="${HOME}/.claude/forge"
SETTINGS="${HOME}/.claude/settings.json"
mkdir -p "$SKILLS_DIR" "$AGENTS_DIR" "$PROFILE_DIR"
for skill in "$FORGE_HOME"/skills/forge-*/; do
  name="$(basename "$skill")"
  ln -sfn "${skill%/}" "$SKILLS_DIR/$name"
  echo "skill: $name -> linked"
done
# Роли агентов ставятся определениями, а не памяткой в скилле: модель зашита
# во frontmatter, поэтому диспетчер не может забыть её передать.
for agent in "$FORGE_HOME"/agents/forge-*.md; do
  name="$(basename "$agent")"
  ln -sfn "$agent" "$AGENTS_DIR/$name"
  echo "agent: ${name%.md} -> linked"
done
# Сторож непрерывности стройки ставится установщиком, а не руками: без него
# диспетчер отдаёт ход владельцу в стыке между волнами, и стройка стоит до
# следующего сообщения. Регистрация идемпотентна и не трогает чужие хуки —
# settings.json принадлежит владельцу, а не системе.
python3 - "$FORGE_HOME" "$SETTINGS" <<'HOOKREG'
import json, pathlib, shutil, sys

forge_home, settings_path = sys.argv[1], pathlib.Path(sys.argv[2])
command = f"python3 {forge_home}/hooks/keep-building.py"

settings = {}
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except Exception:
        # Испорченный settings.json чинит владелец, а не установщик: перезаписать
        # его своей версией значит молча снести все его настройки.
        print("hook: settings.json не читается как JSON — сторож НЕ зарегистрирован, почини файл и повтори")
        raise SystemExit(0)

hooks = settings.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])

# Свои записи узнаём по имени файла сторожа, а не по полной команде: путь меняется
# при переезде репозитория, и сравнение по нему плодило бы дубли сторожей.
ours = [g for g in stop
        if any("keep-building.py" in str(h.get("command", "")) for h in g.get("hooks", []))]
if ours:
    for group in ours:
        for h in group["hooks"]:
            if "keep-building.py" in str(h.get("command", "")):
                h["command"] = command
    action = "обновлён"
else:
    stop.append({"hooks": [{"type": "command", "command": command, "timeout": 20,
                            "statusMessage": "Проверяю, осталась ли работа по стройке"}]})
    action = "зарегистрирован"

settings_path.parent.mkdir(parents=True, exist_ok=True)
if settings_path.exists():
    shutil.copy(settings_path, str(settings_path) + ".forge-backup")
settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"hook: сторож непрерывности {action}")
HOOKREG

if [[ ! -f "$PROFILE_DIR/profile.md" ]]; then
  template="$(cat "$FORGE_HOME/profile.example.md")"
  printf '%s\n' "${template//__FORGE_HOME__/$FORGE_HOME}" > "$PROFILE_DIR/profile.md"
  echo "profile: created"
else
  echo "profile: exists, skipped"
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
