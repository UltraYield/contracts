# Oracle and Rate Provider System

## Why there are two pricing layers

The system separates:

- **Vault valuation layer**: share value and `totalAssets` pricing.
- **Asset conversion layer**: conversion between base asset and supported input/output assets.

This allows independent control of NAV pricing and token conversion logic.

## Vault valuation layer

### `UltraVaultOracle`

Provides base/quote prices and quote retrieval:

- `setPrice`: instant updates
- `scheduleLinearPriceUpdate`: gradual linear updates over a vesting period
- `getQuote`: compute quote amount using current (possibly vested) price

`UltraVault.totalAssets()` relies on oracle quote of:

- `inAmount = totalSupply()`
- `base = share token`
- `quote = vault asset`

### `VaultPriceManager`

Operational controller that updates oracle prices and enforces guardrails:

- per-vault `jump` limit (max update-to-update move)
- per-vault `drawdown` limit (max fall from high-water mark)
- admin-per-vault authorization model

If update breaches limits, manager attempts to pause the vault.

### Intended update policy

Operationally, share price updates are expected to be vested in almost all cases.

- linear vesting updates are the default path
- instant updates are expected to remain mainly for drawdown handling
- this supports smoother user experience while preserving fast downside reflection

## Asset conversion layer

### `UltraVaultRateProvider`

Maps each supported asset to either:

- pegged conversion (decimals normalization only), or
- external `IRateProvider` conversion contract

Used by vault conversion paths:

- `_convertToUnderlying(asset, assets)`
- `_convertFromUnderlying(asset, baseAssets)`

This supports multi-asset deposits/redeems while preserving base accounting.

## Operational flow summary

1. User can deposit/redeem in supported asset.
2. Vault converts asset amount to/from base accounting units using rate provider.
3. Vault share valuation uses oracle price feed for `totalAssets`.
4. Price manager can enforce movement limits and pause on suspicious moves.

## Design assumptions and caveats

- Vault operators perform internal strategy PnL and yield calculations, then publish updated share prices regularly.
- Oracle values may include off-chain assessments and conservative estimates.
- Conversion correctness depends on each configured external rate provider.
