# UltraYield Vault Overview

## What UltraYield vaults do

UltraYield vaults give users access to sophisticated yield-generating strategies across both DeFi and CeFi. Users deposit supported assets and receive vault shares, while strategy capital is managed operationally by designated curators.

The vault tracks each user's claim through shares, while share value is updated through the oracle system based on strategy performance.

## Custody and strategy execution model

Strategy curators typically use an MPC wallet with strict whitelisting rules that constrain:

- which protocols can be accessed
- which contracts can be called
- which addresses can receive transfers

This model is designed to balance two goals:

- strong operational security (for example, preventing arbitrary withdrawals to non-whitelisted addresses)
- flexibility to add or rotate strategy integrations quickly without requiring on-chain verification of every low-level interaction

Upon deposit, funds are transferred to a custody address (`fundsHolder`) jointly controlled by curator and infrastructure parties. Funds are not required to stay in that initial wallet and may be re-allocated across wallets or venues as strategy execution requires.

## Pricing and oracle model

Pricing is produced independently from vault custody execution:

- yield and NAV calculations are performed off-chain by vault operators/curators
- pricing data is published on-chain to the configured oracle address
- oracle ownership/governance can be separate and mutually agreed between curator and infrastructure provider

This setup allows valuation to include conservative treatment of rewards that are economically expected but not yet fully claimable on-chain.

The pricing process is designed to be conservative so fulfilled redemptions remain fully payable under normal operations.

## Standards and compatibility

UltraYield vault contracts follow these standards:

- ERC-4626 (Tokenized Vault)
- ERC-7540 (asynchronous redeems while deposits kept synchronous)
- ERC-7575 (Multi-Asset Vault)
- ERC-165 (Standard Interface Detection)

## Async redemptions

An async redemption flow is required because capital is strategy-managed and does not sit idle in the vault contract for immediate withdrawal.

The lifecycle is:

1. User submits a redeem request.
2. Operators prepare liquidity for pending requests.
3. Operator fulfills redeem request(s), moving them to claimable state.
4. User calls `redeem` or `withdraw` to claim assets.

Important properties:

- Redeem requests are not instant withdrawals.
- Fulfillment timelines depend on each vault specification, but are expected to be no longer than 72 hours.
- Users continue participating in vault performance (yield or drawdown) after requesting redeem and until fulfillment happens.
- Final exit amount is fixed at fulfillment time.
- Users can cancel pending redeem requests at any time before fulfillment.
- After fulfillment, the position is claimable and no longer exposed to subsequent vault yield or drawdown.
- Vault valuation is oracle-based (`totalAssets` uses share pricing), not vault token balance.
