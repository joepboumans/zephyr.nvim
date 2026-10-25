# Vendor plugins extend zephyr.nvim through registries

zephyr.nvim stays vendor-neutral and exposes registries (Toolchain providers, Probe finders) that vendor plugins such as nrf-connect.nvim register into, instead of vendor plugins wrapping zephyr.nvim's API. This keeps one entry point for UIs, lets several vendor plugins coexist in the same Neovim, and means a new vendor needs no change to zephyr.nvim.

## Considered Options

- **Wrap the API**: nrf-connect.nvim re-exports zephyr.nvim with Nordic behaviour layered in. Rejected: UIs would need to know which wrapper to call, and two vendor plugins could not be installed together.
