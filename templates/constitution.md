<!-- constitution.md — the project's principles, which do not change during the build. Filled in by the owner together with the system during the spec and plan phase; approved at the gate before the build; the building agents consult it whenever priorities conflict. -->

# Project constitution

<!-- Project name, date of agreement, one line of status (for example: "approved by the owner 2026-07-29"). -->

## Quality principles

<!-- Three to five items: what matters most for THIS product when decisions conflict (for example: "reliability over shipping features faster", "simplicity over flexibility"). Not platitudes — concrete priorities. -->

## Testing standard

<!-- The mandatory minimum for this project: TDD (red → green → refactor) for new functionality; the coverage threshold is **relative** — no lower than at the previous acceptance (an absolute figure such as 80% is kept as a guide and does not by itself send a block back: by measurement it caught no defect at all, while it does push people to write assertion-free tests for the sake of the percentage). Which kinds of tests are mandatory (unit / integration / e2e) and where the critical path lies that must not ship untested. Plus the rule that is worth more than any coverage threshold: **a check that does not fail on broken input is not a check**. Run every new check against a deliberately broken copy and confirm that it fails AND prints an intelligible reason. Confirm the breakage itself too: if the substitution did not apply, the "negative run" is falsely green — that has happened. -->

## Docs-as-DoD

<!-- Documentation is part of the Definition of Done, not a separate later step. Which documents must be updated together with the code in this project (the block spec, CHANGELOG, the inventory of endpoints and variables, and so on) and what is checked before a task counts as closed. -->

## Security rules

<!-- Secrets never reach git: values live in .env (gitignored), documentation carries only variable names. A committed .env.example with names and safe values is mandatory: without it the project cannot be brought up again — not in another session, not by another person. Validate user input at the system's boundaries. Whatever else is specific to this product (authentication, payments, users' personal data) — list it explicitly. -->

## Demo mode

<!-- A product with an interface must have a live demo that needs no registration: an isolated demo account or workspace, an idempotent seed of representative data, and a light entry point. The demo's language is always English, regardless of the product's language. The demo is isolated from real data and returns to a clean state by itself. -->
