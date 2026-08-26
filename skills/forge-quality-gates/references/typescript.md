# Гейты качества: TypeScript и Node

Сверено 26.08.2026. Источники, версии и способ перепроверки —
`docs/research/2026-08-26-quality-gates.md`.

## Обязательный набор

| Роль | Команда | Чем |
|---|---|---|
| Формат | `prettier --check .` | Prettier с дефолтами; спорить о настройках дороже, чем принять |
| Линт с типами | `eslint .` | ESLint 10, flat config, `typescript-eslint` пресеты `strictTypeChecked` + `stylisticTypeChecked` |
| Типы | `tsc --noEmit` | строгий tsconfig; `noUncheckedIndexedAccess` включать до появления кода |
| Тесты и порог | `vitest run --coverage` | `coverage.thresholds` в конфиге воркспейса |
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

## Скелет линта

```js
// packages/config или корень проекта: eslint.config.mjs
import tseslint from "typescript-eslint";
import sonarjs from "eslint-plugin-sonarjs";
import unicorn from "eslint-plugin-unicorn";
import depend from "eslint-plugin-depend";

export default tseslint.config(
  tseslint.configs.strictTypeChecked,
  tseslint.configs.stylisticTypeChecked,
  {
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
);
```

`unicorn/no-negated-condition` намеренно не включён — дублирует
`sonarjs/no-inverted-boolean-check`.

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
