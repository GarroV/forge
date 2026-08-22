#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
FORGE_HOME="$(cd "$(dirname "$0")/.." && pwd)"
export HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
"$FORGE_HOME/install.sh" > /dev/null
[[ -f "$HOME/.claude/forge/profile.md" ]] || { echo "FAIL: no profile"; exit 1; }
grep -q "forge_home: $FORGE_HOME" "$HOME/.claude/forge/profile.md" || { echo "FAIL: forge_home not substituted"; exit 1; }
echo "custom-marker" >> "$HOME/.claude/forge/profile.md"
"$FORGE_HOME/install.sh" > /dev/null
grep -q "custom-marker" "$HOME/.claude/forge/profile.md" || { echo "FAIL: profile overwritten"; exit 1; }
[[ ! -L "$HOME/.claude/skills/forge-*" ]] || { echo "FAIL: literal glob symlink created"; exit 1; }
for s in "$FORGE_HOME"/skills/forge-*/; do
  name="$(basename "$s")"
  [[ "$(readlink "$HOME/.claude/skills/$name")" == "${s%/}" ]] || { echo "FAIL: symlink $name"; exit 1; }
done
# Определения агентов ставятся тем же установщиком: без них скиллы называют типы
# агентов, которых в реестре нет, и запуск блока падает «agent type not found».
[[ ! -L "$HOME/.claude/agents/forge-*.md" ]] || { echo "FAIL: literal glob symlink created (agents)"; exit 1; }
agents_found=0
for a in "$FORGE_HOME"/agents/forge-*.md; do
  name="$(basename "$a")"
  [[ "$(readlink "$HOME/.claude/agents/$name")" == "$a" ]] || { echo "FAIL: agent symlink $name"; exit 1; }
  agents_found=1
done
(( agents_found == 1 )) || { echo "FAIL: no agent definitions linked"; exit 1; }
# Предупреждение — часть установки, а не любезность: в уже открытой сессии реестр
# агентов обновляется с задержкой, и первый запуск после установки может упасть
# «agent type not found». Проверяются оба совета, потому что порознь они врут:
# только «повтори» оставит человека в цикле, только «перезапусти» погонит его зря.
install_out="$("$FORGE_HOME/install.sh")"
grep -q "задержкой" <<<"$install_out" || { echo "FAIL: no delay warning"; exit 1; }
grep -q "перезапусти" <<<"$install_out" || { echo "FAIL: no restart fallback"; exit 1; }

# Сторож непрерывности: без регистрации в settings.json он не существует для
# харнесса, сколько бы файлов ни лежало в репозитории. Проверяется не наличие
# файла, а именно запись, по которой хук будет вызван.
SETTINGS="$HOME/.claude/settings.json"
[[ -f "$SETTINGS" ]] || { echo "FAIL: settings.json не создан"; exit 1; }
python3 - "$SETTINGS" "$FORGE_HOME" <<'CHECK' || exit 1
import json, sys
settings = json.loads(open(sys.argv[1]).read())
forge_home = sys.argv[2]
stop = settings.get("hooks", {}).get("Stop", [])
cmds = [h.get("command", "") for g in stop for h in g.get("hooks", [])]
ours = [c for c in cmds if "keep-building.py" in c]
if len(ours) != 1:
    print(f"FAIL: сторож зарегистрирован {len(ours)} раз вместо одного: {cmds}")
    raise SystemExit(1)
if forge_home not in ours[0]:
    print(f"FAIL: в команде сторожа не тот путь: {ours[0]}")
    raise SystemExit(1)
CHECK

# Чужие хуки — не наши: settings.json принадлежит владельцу, и установщик,
# который сносит его настройки, опаснее отсутствующего сторожа.
python3 - "$SETTINGS" <<'SEED'
import json, sys
p = sys.argv[1]
settings = json.loads(open(p).read())
settings.setdefault("hooks", {}).setdefault("PreToolUse", []).append(
    {"matcher": "Edit", "hooks": [{"type": "command", "command": "чужой-хук-владельца"}]})
settings["ownKey"] = "не трогать"
json.dump(settings, open(p, "w"), ensure_ascii=False, indent=2)
SEED
"$FORGE_HOME/install.sh" > /dev/null
grep -q "чужой-хук-владельца" "$SETTINGS" || { echo "FAIL: установщик снёс чужой хук"; exit 1; }
grep -q "не трогать" "$SETTINGS" || { echo "FAIL: установщик снёс чужие настройки"; exit 1; }

# Повторная установка не плодит второго сторожа: два одинаковых хука на Stop
# означают два удержания на каждый ход и вдвое больший расход.
"$FORGE_HOME/install.sh" > /dev/null
count="$(python3 -c "
import json,sys
s=json.load(open(sys.argv[1]))
print(sum('keep-building.py' in h.get('command','') for g in s.get('hooks',{}).get('Stop',[]) for h in g.get('hooks',[])))
" "$SETTINGS")"
[[ "$count" == "1" ]] || { echo "FAIL: после повторной установки сторожей $count"; exit 1; }

# Переезд репозитория обновляет путь в существующей записи, а не добавляет вторую:
# иначе после переноса системы владелец получит сторожа, зовущего исчезнувший файл.
python3 - "$SETTINGS" <<'MOVE'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
for g in s["hooks"]["Stop"]:
    for h in g["hooks"]:
        if "keep-building.py" in h.get("command", ""):
            h["command"] = "python3 /старый/путь/hooks/keep-building.py"
json.dump(s, open(p, "w"), ensure_ascii=False, indent=2)
MOVE
"$FORGE_HOME/install.sh" > /dev/null
grep -q "/старый/путь/" "$SETTINGS" && { echo "FAIL: старый путь сторожа не обновлён"; exit 1; }
count="$(python3 -c "
import json,sys
s=json.load(open(sys.argv[1]))
print(sum('keep-building.py' in h.get('command','') for g in s.get('hooks',{}).get('Stop',[]) for h in g.get('hooks',[])))
" "$SETTINGS")"
[[ "$count" == "1" ]] || { echo "FAIL: после переезда сторожей $count"; exit 1; }

# Испорченный settings.json установщик не переписывает своей версией — он говорит
# об этом вслух. Молчаливая перезапись стоила бы владельцу всех его настроек.
cp "$SETTINGS" "$SETTINGS.good"
echo '{ это не json' > "$SETTINGS"
broken_out="$("$FORGE_HOME/install.sh")"
grep -q "не читается как JSON" <<<"$broken_out" || { echo "FAIL: об испорченном settings.json не сказано"; exit 1; }
grep -q "это не json" "$SETTINGS" || { echo "FAIL: испорченный settings.json перезаписан установщиком"; exit 1; }
mv "$SETTINGS.good" "$SETTINGS"

# Про снимок хуков на старте сессии владельцу говорится прямо: иначе он поставит
# систему, продолжит в открытом окне и решит, что сторож не работает.
hook_out="$("$FORGE_HOME/install.sh")"
grep -q "перезапуска" <<<"$hook_out" || { echo "FAIL: не сказано, что сторож включится после перезапуска"; exit 1; }

echo "PASS"
