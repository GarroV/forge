# Project specification

A link shortener: a short code instead of a long address.

## Overview

A service that takes a long address and returns a short code. It exists so links can be
shared in messengers, where a long address takes up half the message.

## Users and scenarios

A guest opens the page → pastes a long link → gets a short one → shares it. Second
scenario: following a short link leads to the original address.

## User stories with priorities

| story | priority | block |
| --- | --- | --- |
| As a guest, I want to shorten a long link without signing up, so I can share it quickly | must | api |
| As a guest, I want to follow a short link and land on the original address | must | api |
| As a guest, I want to see click statistics, so I know whether the link is used | nice | web |

## MVP Definition of Done

Tests green, shortening and redirect pass a smoke test in a live browser, the product is
running on the test platform.

## What we are NOT doing

Registration, personal accounts, custom domains, link expiry.

## Open questions

Whether creating links needs a rate limit — the owner decides as we go (Q001).
