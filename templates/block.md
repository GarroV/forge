<!-- block.md — the spec of one product block. A copy is placed in docs/forge/blocks/<name>.md during the plan phase; from then on the agent responsible for the block maintains it (Docs-as-DoD — updated together with the code, not afterwards). -->

# Block: <!-- block name, e.g. "api" or "web" -->

## Purpose

<!-- What this block does in the product and why it is a separate unit rather than part of another block. Two or three sentences. -->

## API contract

<!-- Exact function signatures / HTTP endpoints / message formats this block provides to other blocks. Example: "POST /api/links {url: string} -> {id: string, short_url: string}". Changed only in agreement with the blocks that depend on it. -->

## Dependencies

<!-- Which other product blocks this one depends on (names from the graph in plan.md) and which external services or libraries it needs (with versions, if known). "—" if there are none. -->

## Definition of Done for the block

<!-- A checkable list for THIS block: tests green, coverage no lower than at the previous acceptance, the project's static checks green, the block's flow smoke-tested for real, the block's documentation updated and the CHANGELOG appended, integration with dependent blocks not broken.

It provides or consumes a contract from the technical plan — a contract check from its own side is mandatory: the consumer verifies that it calls what was declared, the provider that it returns what was declared.

There are screens — visual items are mandatory: the screen matches the reference in docs/forge/design/ (compared by opening both, not from memory), the empty / loading / error / no-access states are drawn, components come from the visual system rather than being drawn again. Without them acceptance lets through a screen that does not look like what was designed: tests green, wrong product.

Every item carries the stage it belongs to (the "stage" column), if the block is not built in one pass. Why: the contract is written for the whole block while the work goes in waves, and the agent receives a list where half the items belong to the fourth wave — on a live run that was three languages and a reference-data admin panel for one block, deployment and CI for another. The only thing that saved it was the dispatcher spelling out the boundary in the assignment, which means the assignment depended on what the dispatcher remembered. The marker puts the boundary back into the contract itself: the agent sees its part, and acceptance checks against the same line. A block built in one pass does not need the column — put "—". -->

| stage | readiness item |
| --- | --- |

## Status

<!-- The block's current status: not_started / in_progress / done / blocked. One line with the date it was last updated. -->
