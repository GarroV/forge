<!-- plan.md — HOW we build: stack, architecture, decomposition into blocks. Filled in during the spec and plan phase from the research report and the brainstorm; block agents read this file as the source of the contracts between blocks. -->

# Technical plan

<!-- Project name, date of agreement. -->

## Stack with rationale

<!-- Every technology choice comes with a "why", not just a name. Example: "PostgreSQL — relational data with a clear schema; the alternative (a document database) was considered and rejected — there are more relationships here than documents". -->

## Architecture

<!-- The top-level picture: which parts the system consists of and how they interact (in prose or as a diagram). Detailed enough to decide where the boundaries between blocks run. -->

## Blocks and dependency graph

<!-- Every block is a logical unit of the product with its own spec (docs/forge/blocks/<name>.md), its own contract and its own working tree. The graph below says which block waits for another's contract to be ready (a real dependency, not merely "related").

A product with an interface must have a `visual` block: the shared visual system (grid, typography, colours, components, states) built from the screen reference in docs/forge/design/. It comes before the blocks that draw screens — otherwise every block invents its own button, and reconciling them afterwards costs more than agreeing up front. It is declared here, not added later: on a live project the block appeared only after the owner said he could not even test the product. -->

```mermaid
graph TD
  %% one node per block, an arrow means "depends on". Example: block_web --> block_api
```

## Contracts between blocks

<!-- For every pair of dependent blocks — exactly what one provides to the other: precise function signatures, endpoints, message formats, data schema. That is what allows blocks to be built in parallel without waiting for each other.

Every contract has an executable check on BOTH sides: the consumer verifies that it calls what was declared, the provider that it returns what was declared. Both live in their own blocks and turn red separately. Why: blocks are built in parallel by agents that cannot see each other, and otherwise a divergence surfaces at merge time — that is, for whoever did not introduce it. This is the very case contract testing was invented for (consumer-driven contracts); we do not bring in the broker machinery — both sides of the contract live in one repository. Basis: docs/research/2026-08-28-testing-industry.md. -->

## Quality gates

<!-- How this project is checked by machine — one row per role. Six roles are mandatory: formatting, type-aware linting, type checking, tests with a coverage threshold, dead code, module boundaries. Tool sets per stack, and situational checks with their conditions for switching on, live in the forge-quality-gates skill. -->

| Role | Command | Tool |
| --- | --- | --- |

<!-- Module boundaries are derived mechanically from the block graph above: a block imports only what it depends on in the graph; the reverse direction is forbidden. This is the only check that catches a violation invisible inside a single working copy and surfacing only at merge time. -->

**Single run command:** <path to an executable, for example `scripts/check`>

<!-- One entry point that runs the whole canonical set and writes the machine-readable report. Block acceptance calls it, the pre-push hook calls it, and CI calls it — all three the same one, otherwise they drift apart and "it's green on my machine" stops meaning anything. It is declared here machine-readably, not described in prose in the README. -->

**Machine-readable run report:** <format and the path the runner writes it to>

<!-- The report acceptance reads instead of the exit code: how many checks ran, how many were skipped and why. Every common runner can emit JUnit XML; a native JSON format works too. The format is declared here rather than hard-wired into the core: runners differ between projects. Not declared — acceptance has nothing to read, and the gate falls back to the exit code, which does not distinguish two hundred green checks from zero registered ones. -->

## Risks

<!-- Risk → mitigation. What can go wrong when integrating blocks, in the choice of stack, during deployment — and what to do if it happens. -->
