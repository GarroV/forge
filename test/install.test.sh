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
# Команда обязана пережить исчезновение файла сторожа. Код возврата команды —
# это решение для харнесса, и `python3` на несуществующем файле отдаёт 2, то
# есть «ход не отдавать»: сессия перестаёт заканчивать ходы и печатает ошибку
# запуска вместо работы. Достаточно переезда репозитория, чтобы это накрыло все
# сессии машины, и починить изнутри нечем.
if "[ -f" not in ours[0] or "exit 0" not in ours[0]:
    print(f"FAIL: команда сторожа не переживёт пропажу файла: {ours[0]}")
    raise SystemExit(1)

# Страж состава коммита ставится тем же установщиком. Его отсутствие не видно по
# поведению — коммиты продолжают проходить, просто уносят в себя чужую работу из
# общего дерева, — поэтому регистрацию проверяем тестом, а не глазами.
pre = settings.get("hooks", {}).get("PreToolUse", [])
scope_groups = [g for g in pre
                if any("guard-commit-scope.py" in str(h.get("command", ""))
                       for h in g.get("hooks", []))]
if len(scope_groups) != 1:
    print(f"FAIL: страж состава коммита зарегистрирован {len(scope_groups)} раз вместо одного")
    raise SystemExit(1)
if scope_groups[0].get("matcher") != "Bash":
    print(f"FAIL: страж навешен не на Bash, а на {scope_groups[0].get('matcher')!r} — "
          "он разбирает команды git и на других инструментах бесполезен")
    raise SystemExit(1)
scope_cmd = [h["command"] for h in scope_groups[0]["hooks"]
             if "guard-commit-scope.py" in h["command"]][0]
if "[ -f" not in scope_cmd or "exit 0" not in scope_cmd:
    print(f"FAIL: команда стража не переживёт пропажу файла: {scope_cmd}")
    raise SystemExit(1)

wave_groups = [g for g in pre
               if any("guard-wave-width.py" in str(h.get("command", ""))
                      for h in g.get("hooks", []))]
if len(wave_groups) != 1:
    print(f"FAIL: ограничитель ширины волны зарегистрирован {len(wave_groups)} раз вместо одного")
    raise SystemExit(1)
if "Agent" not in str(wave_groups[0].get("matcher")):
    print(f"FAIL: ограничитель навешен на {wave_groups[0].get('matcher')!r} — он должен ловить "
          "запуск агентов, иначе ширину волны считать не на чем")
    raise SystemExit(1)
CHECK

# Та же гарантия, проверенная исполнением, а не чтением: структурная проверка
# выше видит форму, эта — результат.
missing_cmd="[ -f /нет/такого/keep-building.py ] || exit 0; python3 /нет/такого/keep-building.py"
set +e
sh -c "$missing_cmd" >/dev/null 2>&1
missing_code=$?
set -e
(( missing_code == 0 )) || { echo "FAIL: команда с пропавшим сторожем вернула $missing_code вместо 0 — это блокировка сессии"; exit 1; }

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

# --off обязан снимать оба механизма стройки. Снятый наполовину хуже любого
# целого состояния: владелец считает, что выключил стройку, а её правила
# продолжают вмешиваться в его собственную работу.
python3 "$FORGE_HOME/hooks/keep-building.py" --off > /dev/null
python3 - "$SETTINGS" <<'OFFCHECK' || exit 1
import json, sys
s = json.loads(open(sys.argv[1]).read())
left = [h.get("command", "")
        for ev in ("Stop", "PreToolUse")
        for g in s.get("hooks", {}).get(ev, [])
        for h in g.get("hooks", [])
        if any(n in str(h.get("command", ""))
               for n in ("keep-building.py", "guard-commit-scope.py", "guard-wave-width.py"))]
if left:
    print(f"FAIL: --off оставил регистрации: {left}")
    raise SystemExit(1)
OFFCHECK
