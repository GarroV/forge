# Technical plan

## Stack with rationale

Python with FastAPI and Postgres: the owner already has experience with them and the
libraries are mature.

## Architecture

One service, two surfaces: an HTTP API and a minimal web page.

## Blocks and dependency graph

Block `api` — link storage and redirect. Block `web` — the page for creating links and
the statistics, depends on the `api` contract.

## Contracts between blocks

`api` provides `POST /links` → `{ code }` and `GET /:code` → `302`. `web` consumes them.

## Quality gates

| Role | Command | Tool |
| --- | --- | --- |
| Formatting | `scripts/check` | ruff format |

**Single run command:** `scripts/check`

**Machine-readable run report:** JUnit XML in `reports/junit.xml`

## Risks

Short-code collision — mitigated by the code length and a check for existence.
