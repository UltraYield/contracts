# Vault Economics

## Economic primitives

- **Base Asset**: base accounting token of the vault (`asset()`).
- **Asset**: one of the vault's supported assets (including the base asset).
- **Shares**: vault ownership units (ERC-20 shares of the vault itself).
- **Share value**: assets per 1 share, sourced through oracle valuation.

## Share pricing model

- `UltraVault.totalAssets()` is computed as an oracle quote of total shares into base asset units.
- Share pricing data is published on-chain to the configured oracle address after off-chain calculations.
- The vault follows the standard ERC-4626-style approach for conversion between shares and assets:
   - `convertToAssets(shares)`
   - `convertToShares(assets)`

## Fee model

The vault supports three fee types:

1. **Performance fee**
   - Charged only when share value is above a high-water mark.
   - Accrues continuously as share value rises above high-water mark.
   - Charged in shares.
   - Max allowed configured rate: 30%.
2. **Management fee**
   - Time-based annualized fee accrued linearly with elapsed time.
   - Charged in shares.
   - Max allowed rate: 5%.
3. **Withdrawal fee**
   - Applied during redeem fulfillment in output asset units.
   - Charged in the asset being withdrawn.
   - Max allowed rate: 1%.

## Fee collection mechanics

Fees are crystallized by `_collectFees()` and minted as shares to `feeRecipient`.

Fee collection occurs on:
- operations that modify the vault's total supply:
   - deposit
   - mint
   - redeem fulfillment
- fee updates
- manual `collectFees()` calls

## Performance fee intuition

- Track `highwaterMark` in share-value terms.
- If current share value is below or equal to high-water mark, no performance fee accrues.
- If above, fee accrues continuously on the gain portion.
- On collection, high-water mark updates to current share value when higher.

## Management fee intuition

Management fee accrues with time:

- proportional to `totalAssets`
- proportional to elapsed seconds since `lastUpdateTimestamp`
- normalized by one year

In plain terms: more TVL and more elapsed time means more management fee accrual.
