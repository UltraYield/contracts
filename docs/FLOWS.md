# Vault Lifecycle

## 1. Deposit and mint flow

### Deposit path

1. User calls `deposit` (base asset) or `depositAsset` (for a supported asset).
2. Vault previews shares from input assets.
3. Vault transfers deposit tokens from user to vault.
4. Vault mints shares to receiver.
5. `UltraVault.afterDeposit` transfers deposited tokens to `fundsHolder`.

## 2. Redeem request flow

1. User/controller calls `requestRedeem` or `requestRedeemOfAsset`.
2. Shares are moved from owner to vault.
3. Pending redeem accounting increases for `(controller, asset)`.
4. Request remains pending until operator fulfillment.

Cancellation is possible (full or partial) via cancel request functions, returning pending shares back to the receiver.

## 3. Fulfillment flow (by operator)

Only `OPERATOR_ROLE` can fulfill:

1. Operator calls `fulfillRedeem` or `fulfillMultipleRedeems`.
2. Shares are converted into claimable asset amounts.
3. Pending redeem is consumed.
4. Claimable redeem is increased.
5. Escrowed shares in vault are burned.

Redeem fulfillment cadence depends on vault operations, with expected completion not exceeding 72 hours.

## 4. Claim flow (user exit)

After fulfillment, users claim assets via:

- `redeem`/`redeemAsset` (exact shares target)
- `withdraw`/`withdrawAsset` (exact assets target)

These consume claimable balances and transfer assets from vault to receiver.

## 5. Paused state behavior

- Deposits/mints are blocked when paused.
- Preview deposit/mint functions return 0 when paused.
- Withdraw/redeem of already claimable amounts continue to function.

This supports incident response while preserving user exit from fulfilled liquidity.

## 6. Address update flow

For oracle/rate provider/funds holder updates:

1. Owner proposes new address.
2. Wait timelock period.
3. Accept within allowed window.
4. Vault pauses automatically on accept.
5. Operators verify setup and unpause when ready.
