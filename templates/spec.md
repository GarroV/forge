<!-- spec.md — WHAT we are building: requirements, scenarios, the MVP readiness criteria. Filled in from the intake, the research report and the brainstorm; read both by the owner at the gate and by the agents that build the blocks. -->

# Project specification

<!-- Project name, one line about the problem the product solves. -->

## Overview

<!-- What this is, who it is for, which problem it solves. Three to five sentences — product level, not technical: this section must be understandable to someone with no context of the build. -->

## Users and scenarios

<!-- Who uses the product (roles) and their main end-to-end scenarios, in prose. Example of the shape: "the user opens the site → searches for a product → adds it to the cart → places the order". -->

## User stories with priorities

<!-- The table below, one row per story. Story shape: "As a <role>, I want <action>, so that <goal>". Priority: must | nice. Block: the name of a block from the graph in plan.md that covers this story — that is what links the story to the plan mechanically rather than by someone's memory.

Why the "block" column: the spec, the plan and the block descriptions are written in one session and drift apart silently — a must story ends up with no block, and simply nobody builds it. The package check compares this column against the set of blocks and turns red if a must story points at a block that does not exist or points at none. For nice stories "—" is acceptable: they may legitimately stay out of the MVP. -->

| story | priority | block |
| --- | --- | --- |
<!-- | As a guest, I want to shorten a long link without signing up, so I can share it quickly | must | api | -->

## MVP Definition of Done

<!-- A concrete, checkable list: what must be true for the MVP to count as ready (tests green, the product running on the test platform, the demo mode working, specific scenarios passing a smoke test). Items you can tick off, not general words. -->

## What we are NOT doing

<!-- Functionality explicitly excluded from the MVP — so that the building agents do not grow the scope themselves and spend cycles on it. -->

## Open questions

<!-- Questions left after the brainstorm, if any: what will be decided during the build rather than blocking the start. Shape: the question in brief + who decides (the owner as we go / the system autonomously). -->
