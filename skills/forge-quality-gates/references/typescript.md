# Гейты качества: TypeScript и Node

Сверено 26.08.2026. Источники, версии и способ перепроверки —
`docs/research/2026-08-26-quality-gates.md`.

Пакеты линта: `eslint`, `typescript-eslint`, `eslint-plugin-sonarjs`,
`eslint-plugin-unicorn`, `eslint-plugin-depend`, `@eslint/json`. Последний нужен
не для красоты: без него `package.json` не линтуется вообще, и правило запрета
зависимостей не срабатывает никогда — подробности в разделе про скелет.

## Обязательный набор

| Роль | Команда | Чем |
|---|---|---|
| Формат | `prettier --check .` | Prettier с дефолтами; спорить о настройках дороже, чем принять |
| Линт с типами | `eslint .` | ESLint 10, flat config, `typescript-eslint` пресеты `strictTypeChecked` + `stylisticTypeChecked` |
| Типы | `tsc --noEmit` | строгий tsconfig; `noUncheckedIndexedAccess` включать до появления кода |
| Тесты и порог | `vitest run --coverage` | `coverage.thresholds` в конфиге; в монорепозитории — только в корневом (см. ниже) |
| Мёртвый код | `knip` | понимает воркспейсы, есть аннотации для CI и постепенное внедрение |
| Границы | `depcruise apps packages` | `dependency-cruiser`; либо `eslint-plugin-boundaries`, если нужна ошибка прямо в редакторе |

## Правила, которые обычно пишут прозой, а надо конфигом

Каждая строка ниже — правило, которое в документах проекта живёт абзацем, хотя
проверяется машиной. Пресеты целиком не подключаются: они шире канона и
пересекаются между собой.

| Правило | Идентификатор |
|---|---|
| функция не помещается в голове | `sonarjs/cognitive-complexity` (порог 15) |
| ветки с одинаковым телом | `sonarjs/no-duplicated-branches`, `sonarjs/no-all-duplicated-branches` |
| вложенный `if` без `else` сливается с внешним | `sonarjs/no-collapsible-if` |
| условие не инвертируется ради `else` | `sonarjs/no-inverted-boolean-check` |
| boolean возвращается выражением | `sonarjs/prefer-single-boolean-return` |
| `switch` внутри `switch` | `sonarjs/no-nested-switch` |
| тернарник в тернарнике | `no-nested-ternary` (ядро ESLint) |
| truthiness только для настоящих boolean | `@typescript-eslint/strict-boolean-expressions` |
| `key` списка из данных, не индекс | `@eslint-react/no-array-index-key` |
| компонент не объявляется внутри компонента | `@eslint-react/no-nested-component-definitions` |
| число не утекает в разметку через `&&` | `@eslint-react/no-leaked-conditional-rendering` |
| объекты и функции не пересоздаются в контексте и пропсах | `@eslint-react/no-unstable-context-value`, `no-unstable-default-props` |
| внешняя ссылка в новой вкладке безопасна | `@eslint-react/dom-no-unsafe-target-blank` |
| разметка не собирается из строки | `@eslint-react/dom-no-dangerously-set-innerhtml` |
| у кнопки есть тип | `@eslint-react/dom-no-missing-button-type` |
| встроенные модули с префиксом `node:` | `unicorn/prefer-node-protocol` |
| элемент с конца — `at(-1)` | `unicorn/prefer-at` |
| глубокая копия — `structuredClone` | `unicorn/prefer-structured-clone` |
| пакет-заменитель платформенного API не подключается | `depend/ban-dependencies` |
| циклов импортов нет | `import-x/no-cycle`, `import-x/no-self-import` |

**Уже включено пресетом `strictTypeChecked` — в прозе не описывать:**
`no-unnecessary-condition` (условие всегда истинно или ложно),
`no-unnecessary-boolean-literal-compare` (сравнение с `true`/`false`),
`no-misused-spread`, `no-deprecated`, `no-non-null-assertion`,
`no-explicit-any`, `only-throw-error`, `switch-exhaustiveness-check`
(включается отдельно, в пресеты не входит).

## Ловушки версий

- `eslint-plugin-unicorn` требует ESLint не ниже 10.4 — проверить версию линтера
  до установки.
- У `eslint-plugin-sonarjs` в README указаны только ESLint 8 и 9, а в
  `package.json` peer включает 10. Верить `package.json`.
- `eslint-plugin-react` под ESLint 10 не работает. Замена — `@eslint-react/eslint-plugin`,
  пресет `recommended-typescript`; проверить, что его правила не дублируют
  `eslint-plugin-react-hooks` (источник истины по хукам — он, он же кормит
  компилятор React).
- `eslint-plugin-jsx-a11y` не поддерживает ESLint 10, последний релиз — октябрь
  2024. Доступность проверять прогоном, не статикой.

## Монорепозиторий

Обязательный набор написан от одиночного пакета. В воркспейсах три команды из
шести не запускаются с первого раза — это не про стиль, а про то, что гейт
краснеет по причине, не связанной с кодом, и его снимают.

| Что ломается | Как правильно |
|---|---|
| Порог покрытия негде положить | В Vitest 4 нет `defineWorkspace` (проверено на 4.1.11: `dist/config.d.ts` экспортирует `defineConfig` и `defineProject`). Проекты объявляются через `test.projects` в корневом конфиге, отчёт покрытия один на прогон — порог живёт на корневом уровне, у отдельного приложения своего нет. |
| `tsc --noEmit` красный на воркспейсе Next | Next 16 генерирует типы роутов отдельным шагом. Порядок: `next typegen`, затем проверка типов. До генерации ошибки идут на импортах сгенерированных типов. |
| `next lint` не существует | Убран в Next 16 (проверено по `packages/next/src/bin/next.ts`: в v15.5.4 команда `lint` есть, в v16.3.3 её нет). Линт запускается ESLint напрямую. |

Плюс роль, которой в наборе шести нет и которая в воркспейсах ломается молча —
**гигиена воркспейсов**, условие включения «больше одного воркспейса»:

| Проверка | Команда | Что ловит |
|---|---|---|
| Установленное совпадает с локом | `yarn install --immutable` в CI | дрейф lockfile: у разработчика одна версия, в CI другая |
| Одна версия зависимости на все воркспейсы | `yarn constraints` (встроено в Yarn 4) | разъезд версий TypeScript/React между приложениями |

Ни то, ни другое не попадает в шесть ролей: границы модулей — про импорты,
мёртвый код — про неиспользуемое.

## Скелет линта

Прогнан на eslint 10.9.1, typescript-eslint 8.68.0, sonarjs 4.2.0, unicorn 73.0.0,
depend 1.5.0, typescript 6.0.3: все правила ниже срабатывают на нарушениях, линт
проходит по `package.json`, по `src/` и по самому конфигу без фатальных ошибок.

```js
// eslint.config.mjs
import tseslint from "typescript-eslint";
import sonarjs from "eslint-plugin-sonarjs";
import unicorn from "eslint-plugin-unicorn";
import depend from "eslint-plugin-depend";
import json from "@eslint/json";

export default tseslint.config(
  {
    // files обязателен. Типизированные наборы без него применяются ко всем
    // файлам, и линт падает на первом же нетипизированном — на package.json
    // или на самом eslint.config.mjs: «You have used a rule which requires
    // type information». Гейт выглядит сломанным по причине, не связанной с
    // кодом, и его снимают.
    files: ["**/*.ts", "**/*.tsx"],
    extends: [tseslint.configs.strictTypeChecked, tseslint.configs.stylisticTypeChecked],
    languageOptions: { parserOptions: { projectService: true } },
    plugins: { sonarjs, unicorn, depend },
    rules: {
      // Пресеты плагинов целиком не включаются: шире канона и дают двойные
      // сообщения на одной строке.
      "sonarjs/cognitive-complexity": ["error", 15],
      "sonarjs/no-collapsible-if": "error",
      "sonarjs/no-inverted-boolean-check": "error",
      "sonarjs/prefer-single-boolean-return": "error",
      "sonarjs/no-nested-switch": "error",
      "sonarjs/no-duplicated-branches": "error",
      "no-nested-ternary": "error",
      "unicorn/prefer-node-protocol": "error",
      "unicorn/prefer-at": "error",
      "depend/ban-dependencies": "error",
      "@typescript-eslint/switch-exhaustiveness-check": "error",
    },
  },
  {
    // Отдельный блок под package.json. Без него depend/ban-dependencies
    // молча не проверяет зависимости: ESLint пропускает файл целиком
    // («File ignored because no matching configuration was supplied»),
    // правило в конфиге есть и не срабатывает никогда.
    files: ["**/package.json"],
    language: "json/json",
    plugins: { json, depend },
    rules: { "depend/ban-dependencies": "error" },
  },
);
```

`unicorn/no-negated-condition` намеренно не включён — дублирует
`sonarjs/no-inverted-boolean-check`.

Что выяснилось на прогоне и стоит знать заранее:

- `depend/ban-dependencies` по умолчанию запрещает **axios** (он в манифесте
  `preferred` библиотеки `module-replacements`, вместе с ещё четырьмя сотнями
  имён). Если пакет выбран осознанно — не отключать правило целиком, а разрешить
  точечно: `["error", { allowed: ["axios"] }]`.
- `sonarjs/no-duplicated-branches` не срабатывает на ветках из одного оператора
  (`if (a) return "x"; else return "x";` проходит). Ловит ветки из двух и более.
- Порог `cognitive-complexity` считается по ветвлениям: функция из
  семнадцати последовательных `if` даёт 17 и краснеет при пороге 15.

## Ситуативные

| Проверка | Чем | Условие |
|---|---|---|
| Мутационный прогон | `@stryker-mutator/core` + `@stryker-mutator/vitest-runner`, `mutate` ограничен критичным модулем, `thresholds.break` | есть модуль, где ошибка стоит денег |
| Диф контракта API | `oasdiff` на сгенерированной схеме | фронт и бэк раскатываются раздельно |
| Бюджеты | Lighthouse CI с `budget.json`, `size-limit` на бандл | есть живой трафик |
| Доступность | `@axe-core/playwright` на ключевых экранах | появились экраны |
| Карантин пакетов | `minimumReleaseAge` пакетного менеджера, запрет install-скриптов | продукт в бою |

## Отклонено

- `jscpd` (порог дублирования) — воюет с правилом «абстракция после
  устоявшегося повтора».
- `eslint-plugin-jsx-a11y` — нет поддержки ESLint 10.
- `@typescript-eslint/explicit-module-boundary-types` — шум на каждом экспорте
  ради выгоды, которой почти нет: тип возврата виден в коде.
