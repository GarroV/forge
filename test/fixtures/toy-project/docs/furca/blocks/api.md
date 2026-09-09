# Block: api

## Purpose

Storing links and redirecting by short code.

## API contract

`POST /links` → `{ code }`; `GET /:code` → `302` to the original address.

## Dependencies

None: this is a base block.

## Definition of Done for the block

Tests green, coverage no lower than at the previous acceptance; creating a link and the
redirect smoke-tested for real.

## Status

in progress
