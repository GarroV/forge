# FURCA Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Переименовать систему Forge в FURCA (скиллы, агенты, канал, пути) шаг за шагом, без разового захода, так что после каждого шага ядро рабочее и тесты зелёные.

**Architecture:** Каждый шаг — один коммит: переименование одной единицы (скилл + принадлежащие ему агенты, или отдельный компонент), обновление всех ссылок на неё в текущих (не исторических) документах и тестах, полный прогон проверки. Старое и новое имя какое-то время сосуществуют в разных частях репозитория — это ожидаемо, порядок шагов важнее скорости.

**Tech Stack:** bash (`install.sh`), markdown-скиллы Claude Code, `test/*.test.sh`, Docker/Postgres (канал), домашний сервер владельца — уже развёрнутый канал уведомлений (репозиторий публичный, поэтому имя и адрес хоста в этом документе не называются, см. `~/.claude/forge/private-names.txt`).

**Spec:** `docs/naming.md` (карта переименования, заполнена целиком) + `GarroV/forge#96` (история решений).

## Global Constraints

Скопировано из `docs/naming.md` и решений владельца 07–08.09.2026:

- Меняется только видимое: имена репозиториев, модулей, схем БД, переменных окружения **вне** зафиксированного списка ниже — не трогаются.
- Автозамена по строке запрещена — каждое вхождение `forge`/`Forge` сверяется по месту, а не заменяется массово: слово остаётся допустимым, где означает не систему.
- Единица шага — компонент целиком: имя (каталог/файл), frontmatter, все ссылки на него в текущих документах, тесты. Половина переименования хуже отсутствия переименования.
- Один шаг = один коммит, чтобы откат был одной командой.
- Порядок: сначала уборка в `install.sh`, затем ядро (скиллы+агенты), затем канон в `dotfiles`, затем профиль/пути, `docs/forge/` в продуктах — последним и отдельным решением.
- Протокол проверки на каждом шаге: полный прогон `test/*.test.sh`, фактический `bash install.sh` без битых симлинков, живой вызов переименованного скилла в чистой сессии, целость профиля.

**Новое, всплывшее при подготовке плана — не было явно в `naming.md`, стоит подтвердить перед стартом:**

1. **Историческую документацию не трогаем.** `docs/plans/`, `docs/research/`, `docs/runs/`, `docs/specs/` — датированные записи о том, что происходило, когда система называлась Forge (159 из 282 вхождений в `docs/` — больше половины). Переписывание задним числом вводит в заблуждение читателя git-истории. Переименовываются только описания **текущего** состояния: `README.md`, `docs/OVERVIEW.md`, `docs/STATUS.md`, `skills/`, `agents/`, `channel/`, `templates/`, `test/`, `config.defaults.md`, `profile.example.md`, канон в `dotfiles`.
2. **`docs/forge/` — путь к данным построенного продукта — НЕ трогаем до последнего шага.** Это не то же самое, что переименование скиллов: строка `docs/forge/` зашита внутри `ORDO`/`CURSUS`/`MISSIO`/`FABRICA` как путь, по которому они читают и пишут состояние **чужого** (построенного) проекта. Флип этой строки происходит одним заходом во всех скиллах сразу, синхронно с переносом пяти продуктовых репозиториев (Задача 9) — разнести на два прохода нельзя: их тесты и наши скиллы должны увидеть новый путь одновременно.
3. **`FORGE_SECRET` уже живёт в проде.** Канал уведомлений развёрнут на реальном хосте владельца с реальным секретом и версией `~/.claude/forge/channel.env` на его машине. Переименование этой переменной — не локальная правка, а скоординированная замена на обеих сторонах (см. Задачу 8).
4. **Решение владельца 09.09.2026: `GarroV/forge` тоже переименовывается — «в самом конце».** Это отменяет для Forge/FURCA рамку «имена репозиториев не трогаются» из решения 07.09.2026 (три соседних задачи ребрендинга — MAXIMUS/DECIMUS/MERIDIUS — эту рамку не меняют, их репозитории остаются как есть). Задача 10 ниже. Исторические ссылки на старое имя (`GarroV/forge#NN` в чужих issue, в `dotfiles/claude/decisions/`) не переписываются — GitHub держит редирект со старого имени репозитория, и это тоже исторические записи.

**Уточнение по объёму, найденное 09.09.2026 при подготовке этого плана:** `naming.md` называл «три построенных продукта» с `docs/forge/`. По факту их **пять**: MAXIMUS, DECIMUS, MERIDIUS — плюс ещё два реальных продуктовых репозитория без кодовых имён (оба не тестовые; реальные имена всех пяти — у владельца и в `~/.claude/forge/private-names.txt`, в публичный репозиторий не попадают, см. раздел безопасности ниже). Карта и `GarroV/forge#96` поправлены отдельным коммитом/комментарием; здесь и в Задаче 9 — уже верное число.

## Как проверяем, что текущие стройки не пострадают

Это главный критерий приёмки каждого шага, не только для задач 8–9.

**Структурная защита, которая уже есть в порядке задач:** Задачи 0–7 меняют только этот репозиторий — имена скиллов, агентов, пути установки. Ни один продуктовый репозиторий (в том числе пять с `docs/forge/`) в них не открывается и не редактируется. Продукт физически не может пострадать от переименования, пока никто не трогает его файлы — а до Задачи 9 никто не трогает.

**Единственные два места реального риска для продуктов:**

- **Задача 8 (PONS/канал)** — единственный канал, которым стройка задаёт вопрос владельцу. Замена секрета мид-флайт молча обрывает канал: агент задаёт вопрос — а он никуда не доходит.
- **Задача 9 (`docs/forge/` → `docs/furca/`)** — прямая правка внутри продуктовых репозиториев.

**Проверка перед каждой из этих двух задач (обязательный шаг, не «по памяти»):** пройти по списку всех пяти репозиториев с `docs/forge/` (список — у владельца, в публичный репозиторий не попадает, см. `private-names.txt`) и посмотреть дату последнего коммита в каждом:

```bash
for p in <репозиторий-1> <репозиторий-2> ...; do
  echo "=== $p ==="; cd ~/Documents/projects/$p && git log -1 --format="%ci %s"; cd - >/dev/null
done
```

Если у какого-то репозитория последний коммит — часы, а не дни (по состоянию на 09.09.2026 это уже так для двух из пяти), задача не стартует без явного «да» владельца, что стройка по этому продукту сейчас не идёт. Дополнительно — спросить `/cursus` (после Задачи 2) по каждому продукту: скилл сам покажет, есть ли незакрытый блок в работе.

**Что НЕ является риском:** переименование скилла/агента (Задачи 0–7), пока для продукта не идёт активная сессия `/forge-build`/`/fabrica` прямо в момент git mv. Если такая сессия есть и её потом придётся возобновлять — единственное следствие: возобновлять нужно уже новым именем команды, данные продукта не задеты.

---

### Задача 0 (обязательный первый шаг): уборка и развязка `install.sh`

**Почему первым:** после первого же переименования скилла его каталог перестаёт называться `forge-*`, и текущий установщик тихо перестаёт его находить (`for skill in "$FORGE_HOME"/skills/forge-*/`) — молчаливый сбой, который не упадёт ни на одном тесте, если тест не написан заранее. Плюс: `install.sh` сейчас только ставит симлинки (`ln -sfn`), никогда не снимает — после переименования в `~/.claude/skills` и `~/.claude/agents` останутся битые ссылки на старое имя.

**Files:**
- Modify: `install.sh:10` (глоб скиллов), `install.sh:17` (глоб агентов), плюс добавить шаг уборки перед созданием новых симлинков
- Test: `test/install.test.sh` (сейчас проверяет поведение через `forge-*`, см. строки 13–24)

- [ ] **Шаг 1: Написать падающую проверку** — добавить в `test/install.test.sh` сценарий: положить в `$FORGE_HOME/skills/` фиктивный каталог `zzz-demo/` (без префикса `forge-`), прогнать `install.sh`, убедиться, что в `~/.claude/skills/zzz-demo` появился корректный симлинк. Второй сценарий: создать в `~/.claude/skills` симлинк `forge-stale -> /nonexistent`, прогнать `install.sh`, убедиться, что он удалён.
- [ ] **Шаг 2: Прогнать тест, убедиться что падает** — `bash test/install.test.sh` — FAIL, потому что глоб всё ещё `forge-*/` и уборки нет.
- [ ] **Шаг 3: Заменить дискавери** — `for skill in "$FORGE_HOME"/skills/*/;` (все прямые подкаталоги `skills/`, а не только `forge-*`) и аналогично `for agent in "$FORGE_HOME"/agents/*.md;`.
- [ ] **Шаг 4: Добавить уборку протухших симлинков** — перед циклом установки: пройти по `~/.claude/skills/*` и `~/.claude/agents/*.md`, для каждого симлинка проверить, что цель существует и лежит внутри `$FORGE_HOME`; если цели нет — удалить симлинк.
- [ ] **Шаг 5: Прогнать тест, убедиться что проходит** — `bash test/install.test.sh` — PASS.
- [ ] **Шаг 6: Прогнать весь набор** — `for f in test/*.test.sh; do bash "$f" || echo "FAIL: $f"; done` — все зелёные.
- [ ] **Шаг 7: Фактическая установка** — `bash install.sh` на реальном `~/.claude`, затем `find -L ~/.claude/skills ~/.claude/agents -maxdepth 1 -type l` — пусто (нет битых ссылок).
- [ ] **Шаг 8: Коммит**

```bash
git add install.sh test/install.test.sh
git commit -m "fix: install.sh снимает протухшие симлинки и не зависит от префикса forge-"
```

**Оценка:** 1.5–2 ч.

---

### Задача 1: ORDO (`forge-new`) + EXPLORATIO (`forge-researcher`)

Агент `forge-researcher` используется только внутри `forge-new` (`skills/forge-new/SKILL.md:162-164`) — переименовывается той же задачей, чтобы не трогать этот файл дважды.

**Files:**
- Rename: `skills/forge-new/` → `skills/ordo/`
- Rename: `agents/forge-researcher.md` → `agents/exploratio.md`
- Modify: `skills/ordo/SKILL.md` (frontmatter `name:`, `agents/exploratio.md` frontmatter `name:`, все внутренние упоминания `forge-new`/`forge-researcher` как имени команды/типа агента)
- Modify (точечно, только строки с `forge-new`/`forge-researcher`): `README.md`, `docs/OVERVIEW.md`, `docs/STATUS.md`, `dotfiles/claude/CLAUDE.global.md` (см. Задачу 6 — если ещё не тронуто, можно отложить туда)
- Test: `test/skills.test.sh` (строка 58: `for creator in forge-build forge-new`; строки 119-123: пары `"forge-new|..."`), `test/agents.test.sh`

**Не трогать:** любые вхождения `docs/forge/` внутри `skills/ordo/SKILL.md` — это путь к данным продукта, меняется в Задаче 9.

- [ ] **Шаг 1: Переименовать каталог и файл**

```bash
git mv skills/forge-new skills/ordo
git mv agents/forge-researcher.md agents/exploratio.md
```

- [ ] **Шаг 2: Обновить frontmatter**

`skills/ordo/SKILL.md`: `name: forge-new` → `name: ordo` (описание/триггеры не трогать — они уже не полагаются на имя).
`agents/exploratio.md`: `name: forge-researcher` → `name: exploratio`.

- [ ] **Шаг 3: Найти и разобрать все внутренние ссылки**

```bash
grep -rn "forge-new\|forge-researcher" skills/ordo/ agents/exploratio.md
```

Каждое вхождение — это либо имя команды (`/forge-new` → `/ordo`), либо `subagent_type: forge-researcher` → `subagent_type: exploratio`, либо путь `agents/forge-researcher.md` → `agents/exploratio.md`. Заменить только эти, не трогая `docs/forge/`.

- [ ] **Шаг 4: Обновить тесты**

`test/skills.test.sh:58` → `for creator in forge-build ordo` (пока `forge-build` не переименован — придёт своим шагом). Строки 119-123: заменить `forge-new|` на `ordo|` в парах, которые ссылаются на этот скилл.
`test/agents.test.sh`: заменить упоминания `forge-researcher` на `exploratio`.

- [ ] **Шаг 5: Точечно обновить текущие документы**

```bash
grep -rn "forge-new\|forge-researcher" README.md docs/OVERVIEW.md docs/STATUS.md
```

Обновить только найденные строки (не весь файл).

- [ ] **Шаг 6: Прогнать весь набор тестов**

```bash
for f in test/*.test.sh; do bash "$f" || echo "FAIL: $f"; done
```

- [ ] **Шаг 7: Фактическая установка**

```bash
bash install.sh
find -L ~/.claude/skills ~/.claude/agents -maxdepth 1 -type l
```
Ожидание: пусто, `~/.claude/skills/ordo` и `~/.claude/agents/exploratio.md` — рабочие симлинки.

- [ ] **Шаг 8: Живой вызов** — в чистой сессии Claude Code набрать `/ordo`, убедиться, что скилл срабатывает и стартует анкету.

- [ ] **Шаг 9: Коммит**

```bash
git add -A
git commit -m "feat(rename): forge-new → ordo, forge-researcher → exploratio"
```

**Оценка:** 1.5–2 ч.

---

### Задача 2: CURSUS (`forge-status`)

**Files:**
- Rename: `skills/forge-status/` → `skills/cursus/`
- Modify: `skills/cursus/SKILL.md` (frontmatter, самоссылки — не трогать литералы `docs/forge/`)
- Modify (точечно): `README.md`, `docs/OVERVIEW.md`, `docs/STATUS.md`
- Test: `test/skills.test.sh` (строки с `"forge-status|..."`)

- [ ] **Шаг 1:** `git mv skills/forge-status skills/cursus`
- [ ] **Шаг 2:** `name: forge-status` → `name: cursus` во frontmatter
- [ ] **Шаг 3:** `grep -rn "forge-status" skills/cursus/` и разобрать каждое (имя команды, не `docs/forge/`)
- [ ] **Шаг 4:** обновить пары в `test/skills.test.sh` (`"forge-status|..."` → `"cursus|..."`)
- [ ] **Шаг 5:** точечно обновить `README.md`, `docs/OVERVIEW.md`, `docs/STATUS.md` по факту grep
- [ ] **Шаг 6:** `for f in test/*.test.sh; do bash "$f" || echo "FAIL: $f"; done`
- [ ] **Шаг 7:** `bash install.sh` + проверка битых симлинков
- [ ] **Шаг 8:** живой вызов `/cursus` в чистой сессии
- [ ] **Шаг 9:** коммит `feat(rename): forge-status → cursus`

**Оценка:** 1–1.5 ч.

---

### Задача 3: ADMISSIO (`forge-quality-gates`)

Тот же протокол, что Задача 2, для `skills/forge-quality-gates/` → `skills/admissio/`. Ссылки — в `test/skills.test.sh` (пара `"forge-quality-gates|..."`), `README.md`, `docs/OVERVIEW.md`.

- [ ] Шаг 1: `git mv skills/forge-quality-gates skills/admissio`
- [ ] Шаг 2: frontmatter `name: admissio`
- [ ] Шаг 3: `grep -rn "forge-quality-gates" skills/admissio/` — разобрать
- [ ] Шаг 4: обновить пару в `test/skills.test.sh`
- [ ] Шаг 5: точечно обновить `README.md`, `docs/OVERVIEW.md`
- [ ] Шаг 6: полный прогон тестов
- [ ] Шаг 7: `bash install.sh` + проверка симлинков
- [ ] Шаг 8: живой вызов `/admissio`
- [ ] Шаг 9: коммит `feat(rename): forge-quality-gates → admissio`

**Оценка:** 1–1.5 ч.

---

### Задача 4: MISSIO (`forge-deploy`)

Тот же протокол для `skills/forge-deploy/` → `skills/missio/`. Ссылки — три пары в `test/skills.test.sh` (`"forge-deploy|Смоук..."`, `"forge-deploy|запиши способ отката"`), `README.md`, `docs/OVERVIEW.md`, `docs/STATUS.md`.

- [ ] Шаг 1: `git mv skills/forge-deploy skills/missio`
- [ ] Шаг 2: frontmatter `name: missio`
- [ ] Шаг 3: `grep -rn "forge-deploy" skills/missio/` — разобрать (не трогать `docs/forge/`)
- [ ] Шаг 4: обновить пары в `test/skills.test.sh`
- [ ] Шаг 5: точечно обновить `README.md`, `docs/OVERVIEW.md`, `docs/STATUS.md`
- [ ] Шаг 6: полный прогон тестов
- [ ] Шаг 7: `bash install.sh` + проверка симлинков
- [ ] Шаг 8: живой вызов `/missio`
- [ ] Шаг 9: коммит `feat(rename): forge-deploy → missio`

**Оценка:** 1–1.5 ч.

---

### Задача 5: FABRICA (`forge-build`) + ARTIFEX + OPTIO + NORMA

Самая большая единица: `forge-build` — самый длинный SKILL.md в репозитории и единственное место, где упоминаются все три оставшихся агента (`forge-block-agent` — строки 360-362, 428; `forge-executor` — строка 408; `forge-visual-checker` — строки 48, 562). Переносится одной задачей, чтобы не трогать этот файл трижды.

**Files:**
- Rename: `skills/forge-build/` → `skills/fabrica/`
- Rename: `agents/forge-block-agent.md` → `agents/artifex.md`
- Rename: `agents/forge-executor.md` → `agents/optio.md`
- Rename: `agents/forge-visual-checker.md` → `agents/norma.md`
- Modify: `skills/fabrica/SKILL.md`, три файла агентов (frontmatter)
- Test: `test/skills.test.sh` (пары `"forge-build|..."` и цикл `for creator in forge-build forge-new` — второе имя уже станет `ordo` из Задачи 1), `test/agents.test.sh`, `test/commit-scope.test.sh`, `test/wave-width.test.sh` (проверить, ссылаются ли на `forge-build` по имени)

- [ ] **Шаг 1: Переименовать каталог и три файла агентов**

```bash
git mv skills/forge-build skills/fabrica
git mv agents/forge-block-agent.md agents/artifex.md
git mv agents/forge-executor.md agents/optio.md
git mv agents/forge-visual-checker.md agents/norma.md
```

- [ ] **Шаг 2: Обновить frontmatter всех четырёх файлов** — `name: forge-build` → `name: fabrica`, `name: forge-block-agent` → `name: artifex`, `name: forge-executor` → `name: optio`, `name: forge-visual-checker` → `name: norma`.

- [ ] **Шаг 3: Разобрать все внутренние ссылки**

```bash
grep -n "forge-build\|forge-block-agent\|forge-executor\|forge-visual-checker" skills/fabrica/SKILL.md
```

По списку из подготовки: строки 48, 360-362, 408, 428, 562 — заменить `subagent_type` и упоминания имени роли на новые (`artifex`, `optio`, `norma`); не трогать `docs/forge/`, `<forge_home>/agents/...` пути к самим файлам агентов (эти пути меняются тоже, но именно на новые файлы: `<forge_home>/agents/artifex.md` и т.д.).

- [ ] **Шаг 4: Обновить `test/skills.test.sh`** — цикл `for creator in forge-build forge-new` → `for creator in fabrica ordo`; пары `"forge-build|..."`, `"forge-deploy|..."` (последнее уже должно быть `missio` из Задачи 4, если задачи идут по порядку) → `"fabrica|..."`.

- [ ] **Шаг 5: Обновить `test/agents.test.sh`** — заменить три имени агентов.

- [ ] **Шаг 6: Проверить `test/commit-scope.test.sh` и `test/wave-width.test.sh`**

```bash
grep -n "forge-build\|forge-block-agent" test/commit-scope.test.sh test/wave-width.test.sh
```
Обновить найденные вхождения.

- [ ] **Шаг 7: Точечно обновить `README.md`, `docs/OVERVIEW.md`, `docs/STATUS.md`**

- [ ] **Шаг 8: Полный прогон тестов** — `for f in test/*.test.sh; do bash "$f" || echo "FAIL: $f"; done`

- [ ] **Шаг 9: Фактическая установка** — `bash install.sh` + проверка битых симлинков (5 скиллов + 4 агента к этому моменту переименованы).

- [ ] **Шаг 10: Живой прогон** — короткая служебная стройка (`/fabrica` на тестовом проекте), убедиться, что диспетчер запускает `subagent_type: artifex`, а блок-агент — `subagent_type: optio` и `subagent_type: norma` для сверки экрана.

- [ ] **Шаг 11: Коммит**

```bash
git add -A
git commit -m "feat(rename): forge-build → fabrica, agents → artifex/optio/norma"
```

**Оценка:** 2.5–3 ч (самая большая задача ядра).

---

### Задача 6: DISCIPLINA (`forge-usage`) + канон в `dotfiles`

Выполняется вместе, потому что канон (`CLAUDE.global.md`, раздел 5) называет `forge-new`/`forge-build`/`forge-status`/`forge-usage` в одном абзаце — дешевле поправить разом, когда все имена уже известны из Задач 1–5.

**Files (репозиторий `dotfiles`):**
- Rename: `dotfiles/claude/skills/forge-usage/` → `dotfiles/claude/skills/disciplina/`
- Modify: `dotfiles/claude/skills/disciplina/SKILL.md` (frontmatter, самоссылки, упоминания `forge-new`/`forge-build`/`forge-status` внутри текста скилла — если есть, обновить на `ordo`/`fabrica`/`cursus`)
- Modify: `dotfiles/claude/CLAUDE.global.md` — абзац в разделе 5 (строки ~94-97: «Скиллы `forge-new` / `forge-build` / `forge-status`... скилл `forge-usage`... issue в `GarroV/forge`») — заменить имена скиллов, оставить `GarroV/forge` как есть (имя репозитория не меняется, см. Global Constraints п.4)
- Modify: строка 49 того же файла («Шероховатость Forge — в `GarroV/forge`») — слово «Forge» здесь означает систему, менять на «FURCA», путь репозитория не трогать

- [ ] **Шаг 1:** `git mv dotfiles/claude/skills/forge-usage dotfiles/claude/skills/disciplina`
- [ ] **Шаг 2:** frontmatter `name: disciplina`
- [ ] **Шаг 3:** `grep -n "forge" dotfiles/claude/skills/disciplina/SKILL.md` — разобрать каждое
- [ ] **Шаг 4:** обновить абзац в `CLAUDE.global.md` — имена скиллов на новые, `GarroV/forge` не трогать
- [ ] **Шаг 5:** прогнать `install.sh` из `dotfiles` (если там свой установщик для личного слоя — проверить `dotfiles/install.sh` или аналог) и убедиться, что `disciplina` встал на место `forge-usage` без дубля
- [ ] **Шаг 6:** живой вызов — в новой сессии убедиться, что триггеры `disciplina` (RU/EN) по-прежнему срабатывают на «фордж», «стройка», «forge», «build» (описание не менялось, только имя)
- [ ] **Шаг 7:** коммит в `dotfiles` (`feat(rename): forge-usage → disciplina, канон называет новые имена FURCA`)

**Оценка:** 1 ч.

---

### Задача 7: Профиль и пути (`FORGE_HOME`, `~/.claude/forge/`, `.forge-backup`)

Требует переноса содержимого, а не установки с нуля — на диске владельца уже лежит `~/.claude/forge/profile.md` с личными настройками.

**Files:**
- Modify: `install.sh:4` (`FORGE_HOME` → `FURCA_HOME`), `install.sh:7` (`PROFILE_DIR="${HOME}/.claude/forge"` → `.../furca`, плюс логика переноса: если `~/.claude/furca/` не существует, а `~/.claude/forge/` существует — переместить, не создавать с нуля), `install.sh:94` (`.forge-backup` → `.furca-backup`), `install.sh:99-100` (шаблон `__FORGE_HOME__` → `__FURCA_HOME__`)
- Modify: `profile.example.md` (плейсхолдер `__FORGE_HOME__`)
- Modify: `test/install.test.sh` (строки 8-24 — пути `$HOME/.claude/forge/profile.md` → `.../furca/...`)

**Не трогать в этой задаче:** `channel/setup.sh` — там путь `~/.claude/forge/channel.env` меняется в Задаче 8, сразу на уже актуальный `~/.claude/furca/`, одним заходом (не редактировать этот файл дважды).

- [ ] **Шаг 1: Обновить падающий тест** — в `test/install.test.sh` заменить ожидаемые пути на `~/.claude/furca/...`, добавить сценарий: положить старый `~/.claude/forge/profile.md` с маркером, прогнать установщик, убедиться что маркер сохранился в `~/.claude/furca/profile.md`, а `~/.claude/forge/` больше не единственный источник.
- [ ] **Шаг 2: Прогнать, убедиться что падает.**
- [ ] **Шаг 3: Переименовать переменную и путь в `install.sh`** — `FORGE_HOME` → `FURCA_HOME` везде по файлу; `PROFILE_DIR` на новый путь; перед созданием профиля — если старый `~/.claude/forge/` существует и нового ещё нет, `mv` содержимого, а не перезапись с шаблона.
- [ ] **Шаг 4: Обновить `.forge-backup` → `.furca-backup`, `__FORGE_HOME__` → `__FURCA_HOME__`** в `install.sh` и `profile.example.md`.
- [ ] **Шаг 5: Прогнать тест, убедиться что проходит.**
- [ ] **Шаг 6: Полный прогон** `test/*.test.sh`.
- [ ] **Шаг 7: Фактическая установка на реальном `~/.claude`** — критично проверить, что существующий профиль владельца перенёсся, а не потерялся: `diff` содержимого `profile.md` до и после (сохранить копию перед прогоном).
- [ ] **Шаг 8: Коммит** `feat(rename): FORGE_HOME → FURCA_HOME, профиль переезжает в ~/.claude/furca/ с переносом содержимого`

**Оценка:** 1.5–2 ч (риск в шаге переноса — тестировать на копии профиля, не на единственной живой копии).

---

### Задача 8: PONS (канал уведомлений)

Самая рискованная задача: канал уже развёрнут на реальном хосте владельца с реальным `FORGE_SECRET` и парой владелец↔бот. Ломать её нельзя — это единственный канал вопросов стройки. Выполнять только когда стройка не идёт (иначе PONS в процессе переименования не донесёт вопрос).

**Files:**
- Modify: `channel/docker-compose.yml` (переменная `FORGE_SECRET` → `FURCA_SECRET`, комментарий «Канал Forge» → «Канал FURCA»)
- Modify: `channel/setup.sh` (строки 6, 25 — путь `~/.claude/forge/channel.env` → `~/.claude/furca/channel.env`; строки 127-141, 166 — `FORGE_SECRET` → `FURCA_SECRET`; строка 86 — префикс `forge-` в `PAIR_CODE` можно оставить или сменить на `furca-`, не критично функционально)
- Modify: `channel/bot/main.py:50,55,69` — `FORGE_SECRET` → `FURCA_SECRET`, логгер `"forge-channel"` → `"furca-channel"`
- Modify: `channel/README.md`
- Test: `test/channel.test.sh`, `test/channel-db.test.sh` (проверить упоминания `FORGE_SECRET`)
- **Внешнее:** `.env` на хосте владельца (доступ и адрес — вне этого документа, реальный работающий контейнер), локальный `~/.claude/furca/channel.env` владельца

**Не трогать:** имена БД/значения в `test_db.py`/`test_api.py` вида `"kind": "block", "project": "forge"` — это тестовые данные примера проекта (аналогично `"shop"`, `"my-app_2"` в том же файле), не системный идентификатор.

- [ ] **Шаг 1: Обновить код и тесты** — переименовать переменную во всех перечисленных файлах, прогнать `test/channel.test.sh` и `test/channel-db.test.sh` локально (они, вероятно, поднимают контейнер через тот же `docker-compose.yml` в изолированном виде — проверить, что не задевают продовый).
- [ ] **Шаг 2: Подготовить новый секрет** — сгенерировать `FURCA_SECRET` (не обязательно то же значение, что было в `FORGE_SECRET` — это внутренний секрет пары владелец↔бот, ротация здесь безопасна и даже полезна).
- [ ] **Шаг 3: Обновить `.env` на хосте владельца** — по факту, через доступ, который владелец использует для этого сервера (не по памяти), добавить `FURCA_SECRET`, оставить `FORGE_SECRET` временно на случай отката.
- [ ] **Шаг 4: Пересобрать и перезапустить контейнер бота** — `docker compose up -d --build bot` на этом хосте.
- [ ] **Шаг 5: Обновить локальный `~/.claude/furca/channel.env`** владельца с новым секретом (после Задачи 7 путь уже `furca/`).
- [ ] **Шаг 6: Живая проверка пары** — отправить тестовый вопрос через канал, убедиться, что владелец получает сообщение в Telegram и ответ доходит обратно.
- [ ] **Шаг 7: Убрать `FORGE_SECRET` из `.env` на сервере** — только после подтверждённой живой проверки шага 6.
- [ ] **Шаг 8: Коммит** `feat(rename): FORGE_SECRET → FURCA_SECRET, канал переведён на новый секрет`

**Оценка:** 2–3 ч, из них минимум треть — ожидание живой проверки на хосте владельца, а не работа с кодом.

---

### Задача 9: `docs/forge/` → `docs/furca/`

Затрагивает одновременно: все 5 переименованных скиллов (буквальную строку `docs/forge/` внутри их логики) и **пять** построенных продуктов — MAXIMUS, DECIMUS, MERIDIUS, плюс ещё два без кодовых имён (реальные имена — у владельца, см. Global Constraints и `private-names.txt`; уточнено 09.09.2026 — `naming.md` изначально называл только три). Делается одним заходом, потому что скилл и продукт должны увидеть новый путь синхронно.

**Перед стартом — обязательно прогнать проверку активности из раздела «Как проверяем, что текущие стройки не пострадают» выше.** Два из пяти продуктов на момент подготовки плана коммитились в последние сутки — без явного подтверждения владельца, что стройка по ним сейчас не идёт, эту задачу не начинать.

**Files (этот репозиторий):**
- Modify: `skills/ordo/SKILL.md`, `skills/cursus/SKILL.md`, `skills/missio/SKILL.md`, `skills/fabrica/SKILL.md` — заменить `docs/forge/` → `docs/furca/` (все вхождения, это единственное место, где массовая замена по строке безопасна — она везде означает путь, а не текст про систему)
- Modify: `templates/block.md`, `templates/block-agent-brief.md`, `templates/plan.md`, `templates/retro.md`, `templates/intake.md`, `templates/state/decisions.md`
- Modify: `test/fixtures/edge-statuses/docs/forge/` → `test/fixtures/edge-statuses/docs/furca/`, `test/fixtures/toy-project/docs/forge/` → `.../docs/furca/` (переименовать сами фикстуры-каталоги)
- Test: `test/docs.test.sh`, `test/templates.test.sh`, `test/state-format.test.sh`

**Files (пять продуктовых репозиториев, каждый — отдельный `git mv` + прогон их тестов):** MAXIMUS, DECIMUS, MERIDIUS и ещё два продукта без кодовых имён. Точный список реальных путей — в `~/.claude/forge/private-names.txt` и у владельца; в публичном репозитории FURCA он не называется. В каждом: `docs/forge/` → `docs/furca/`.

- [ ] **Шаг 1: Заменить путь во всех 4 SKILL.md**

```bash
grep -rln "docs/forge" skills/ | xargs sed -i '' 's#docs/forge/#docs/furca/#g'
```
Затем вручную сверить diff — убедиться, что не задета ни одна ссылка на `<forge_home>` (путь установки, не путь продукта) и ни одно упоминание слова «Forge-проект» как текста (эти строки можно оставить или тоже поправить на «FURCA-проект» — решить по месту, отдельно от пути).

- [ ] **Шаг 2: Заменить путь в шаблонах**

```bash
grep -rln "docs/forge" templates/ | xargs sed -i '' 's#docs/forge/#docs/furca/#g'
```

- [ ] **Шаг 3: Переименовать тестовые фикстуры**

```bash
git mv test/fixtures/edge-statuses/docs/forge test/fixtures/edge-statuses/docs/furca
git mv test/fixtures/toy-project/docs/forge test/fixtures/toy-project/docs/furca
```
Обновить пути внутри `test/docs.test.sh`, `test/templates.test.sh`, `test/state-format.test.sh`, где они ссылаются на эти фикстуры.

- [ ] **Шаг 4: Полный прогон тестов ядра**

```bash
for f in test/*.test.sh; do bash "$f" || echo "FAIL: $f"; done
```

- [ ] **Шаг 5: Коммит в этом репозитории**

```bash
git add -A
git commit -m "feat(rename): docs/forge/ → docs/furca/ — путь к данным продукта"
```

- [ ] **Шаг 6: Перенос в пяти продуктовых репозиториях** — по одному: `git mv docs/forge docs/furca`, прогнать собственный тестовый набор репозитория (какой есть), прогнать `/cursus` на этом продукте вручную и убедиться, что он видит `docs/furca/` и не жалуется «это не FURCA-проект». Пять отдельных коммитов в пяти репозиториях.

- [ ] **Шаг 7: Финальная сверка** — `grep -rn "docs/forge" .` (в этом репозитории, исключая `docs/plans/`, `docs/research/`, `docs/runs/`, `docs/specs/` — там путь исторически верен) должен вернуть пусто.

**Оценка:** 4–5 ч (из них ~2.5 ч — по пяти продуктовым репозиториям).

---

### Задача 10 (последняя, отдельное решение владельца 09.09.2026): переименование репозитория `GarroV/forge` → `GarroV/furca`

Выполняется после Задачи 9 — к этому моменту `FURCA_HOME`/профиль (Задача 7) уже устроены так, что путь установки читается из переменной, а не хардкожен, и перенос локального каталога репозитория не потребует правки внутренней логики, только повторной установки.

**Files (этот репозиторий):**
- Переименование на GitHub, локальный remote, при желании — локальный каталог

**Files (репозиторий `dotfiles`, ссылки уже найдены 09.09.2026):**
- Modify: `dotfiles/README.md:142` — таблица со ссылкой на репозиторий
- Modify: `dotfiles/projects.sh:14` — строка `GarroV/forge # spec-driven разработка...`
- Modify: `dotfiles/claude/CLAUDE.global.md:49,97` — упоминания `GarroV/forge` как адреса для issue
- Modify: `dotfiles/claude/skills/disciplina/SKILL.md` (переименован в Задаче 6) — путь `~/Documents/projects/forge` и `GarroV/forge`, строки 12 и 22 (по состоянию на 09.09.2026, до переименования файла в Задаче 6 это был `forge-usage/SKILL.md`)

**Не трогать:** `dotfiles/claude/decisions/2026-09-03-workbench.md:46` (`GarroV/forge#78`) — историческая запись решения, не переписывается; GitHub держит редирект со старого имени репозитория, ссылка останется рабочей.

- [ ] **Шаг 1: Проверить, что прямо сейчас не идёт стройка ни по одному из пяти продуктов** — та же команда, что в разделе «Как проверяем, что текущие стройки не пострадают».

- [ ] **Шаг 2: Переименовать репозиторий на GitHub**

```bash
gh repo rename furca --repo GarroV/forge
```

- [ ] **Шаг 3: Обновить локальный remote**

```bash
cd ~/Documents/projects/forge
git remote set-url origin https://github.com/GarroV/furca.git
git remote -v   # проверить, что оба (fetch/push) указывают на новый адрес
```

- [ ] **Шаг 4: Перенести локальный каталог для единообразия с именем репозитория**

```bash
cd ~/Documents/projects
mv forge furca
cd furca
bash install.sh   # FURCA_HOME пересчитается от нового пути, профиль не потеряется (логика переноса из Задачи 7)
find -L ~/.claude/skills ~/.claude/agents -maxdepth 1 -type l   # пусто
```

- [ ] **Шаг 5: Обновить ссылки в `dotfiles`** — по списку выше, точечно, не трогая историческую запись.

- [ ] **Шаг 6: Прогнать тесты `dotfiles`, если есть, и полный набор `test/*.test.sh` в переименованном каталоге**

- [ ] **Шаг 7: Живая проверка** — `gh issue list --repo GarroV/furca` показывает открытые задачи; `git push`/`git pull` работают из нового каталога; переименованный скилл (`/disciplina` или любой из ядра) срабатывает в чистой сессии.

- [ ] **Шаг 8: Коммит в `dotfiles`**

```bash
git add README.md projects.sh claude/CLAUDE.global.md claude/skills/disciplina/SKILL.md
git commit -m "feat(rename): GarroV/forge → GarroV/furca, локальный путь ~/Documents/projects/furca"
```

**Оценка:** 1–1.5 ч.

---

## Итоговая оценка

| Задача | Часы |
|---|---|
| 0. `install.sh` — уборка и развязка от префикса | 1.5–2 |
| 1. ORDO + EXPLORATIO | 1.5–2 |
| 2. CURSUS | 1–1.5 |
| 3. ADMISSIO | 1–1.5 |
| 4. MISSIO | 1–1.5 |
| 5. FABRICA + ARTIFEX + OPTIO + NORMA | 2.5–3 |
| 6. DISCIPLINA + канон в dotfiles | 1 |
| 7. Профиль и пути | 1.5–2 |
| 8. PONS (канал, живой секрет) | 2–3 |
| 9. `docs/forge/` → `docs/furca/` + 5 продуктов | 4–5 |
| 10. Переименование репозитория `GarroV/forge` → `GarroV/furca` | 1–1.5 |
| **Итого** | **≈ 18.5–25 ч, центр ≈ 21.5 ч** |

Это время сфокусированной работы (грep-сверка-правка-тест-коммит на шаг), не календарное время: по решению владельца от 08.09.2026 и 09.09.2026 переименование делается «позже и постепенно, по одному шагу за раз» — одиннадцать задач (0–10) естественно растянутся на отдельные сессии, каждая начинается заново по этому файлу. Каждая задача самодостаточна и не блокирует остальную работу над Forge/FURCA между ними — можно останавливаться после любого коммита, текущие продукты (5 репозиториев с `docs/forge/`) в это время ничем не затронуты, кроме двух явно помеченных задач.

Отдельно от общей суммы: Задача 8 (PONS) и Задача 9 (`docs/forge/` в продуктах) требуют окна, когда ни по одному из пяти продуктов стройка точно не идёт — проверка вынесена в раздел «Как проверяем, что текущие стройки не пострадают» и обязательна перед стартом каждой из двух задач, а не разово в начале всего плана. Задача 8 дополнительно требует доступа к хосту владельца, который проверяется по факту, а не по памяти.
