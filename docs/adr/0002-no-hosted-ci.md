# 2. No hosted CI

Date: 2026-10-25

## Status

Accepted

## Context

GitHub Actions runs on these private repos cost money. The test suite is small and runs headless in seconds with `make test`.

## Decision

zephyr.nvim and nrf-connect.nvim have no hosted CI. The workflows were removed, and none get added back. Tests run locally before a PR is opened or merged.

## Consequences

- Nobody checks a PR automatically, so whoever opens or merges it runs `make test` (and on both Neovim 0.10 and stable when touching version-specific APIs).
- nrf-connect.nvim no longer needs a token to check out the private zephyr.nvim.
