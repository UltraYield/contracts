# Vendored Chainlink CCIP contracts

Minimal subset of the Chainlink CCIP Solidity contracts needed by `src/crosschain`.
Vendored directly (instead of a submodule) because the upstream source is the full
`smartcontractkit/ccip` monorepo, which is far too large to clone in CI.

- Source: https://github.com/smartcontractkit/ccip (`contracts/`)
- Pinned commit: `171f9f0cf249765116e3131b61f5b4157566f25f`
- License: MIT (preserved in each file)

Files are copied verbatim, preserving the original `src/v0.8/...` layout so their
relative imports and the `@chainlink/contracts-ccip/` remapping resolve unchanged.
To update, copy the corresponding files from the same upstream paths.
