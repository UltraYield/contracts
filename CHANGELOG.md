# Changelog

## 2.0.0-rc.0 (2026-06-30)

V2 is a major upgrade of the UltraVault system. Vault accounting moves to a single 1e18 oracle share-price model, and the release adds instant redemptions, compliance/allowlist vault variants, a deployment factory, a cross-chain (CCIP) pricing stack, and a toolkit of composable rate providers.

V2 ships as an **upgrade of the existing V1 proxies**: `initializeV2` migrates live addresses into a new key-based registry and rescales stored values into the 1e18 price space. The V1 contracts are preserved verbatim under `src/legacy/v1/`.

### Highlights

- **Instant redeem** — `instantRedeem(...)` lets users exit immediately against idle liquidity from a dedicated exitpoint, paying `withdrawalFee + instantRedeemPremium` (premium capped at 0.5%), with a `minAssets` slippage guard.
- **Compliance & allowlist vaults** — `UltraVault` is now an abstract base with two concrete variants: `CompliantUltraVault` (freeze list + force-burn) and `AllowlistUltraVault` (ownership restricted to an allowlist).
- **Vault factory** — `UltraVaultFactory` deploys versioned vault proxies via CREATE2 from a maintained implementation registry.
- **Cross-chain pricing** — prices set on the main chain propagate to remote chains over Chainlink CCIP (`VaultPriceManager` → `RemoteVaultPriceManager`).
- **Rebuilt oracle** — `UltraVaultOracle` exposes a single deterministic share-price curve (a pure function of `block.timestamp`); the imperative `setPrice`/`scheduleLinearPriceUpdate` API is gone.
- **Rate-provider toolkit** — new `AnyERC4626VaultRateProvider`, `ChainlinkRateProvider`, `StableChainlinkRateProvider`, and `ComposableRateProvider` building blocks.
- **ETH adapter** — `UltraVaultEthAdapter` wraps native ETH deposits/redemptions around a WETH vault.
- **Async-redeem upgrades** — opt-in `autoClaim` (fulfillment delivers assets in the same tx) and operator-driven redeem cancellation.

---

### Vaults

**UltraVault** — now an `abstract` base; deploy a concrete variant (`CompliantUltraVault` / `AllowlistUltraVault`) instead.
- *Breaking:* conversion & fee math rebuilt on the oracle's 1e18 share price; V1 storage is rescaled by `initializeV2` (high-water mark, and `Totals` fields `totalSupply`→`totalShares`, `shareValue`→`sharePrice`).
- *Breaking:* `initialize` gains `instantRedeemExitpoint`, `upgradeModule`, `freezeRegistry`; the funds-holder/oracle propose-accept methods, views, events and errors are removed in favor of the shared key-based address registry (zero address still rejected, now via `ZeroAddressInput`).
- *Breaking:* `accruedFees()` now returns `(uint256 managementFee, uint256 performanceFee)` (drops `accruedManagementFees`/`accruedPerformanceFees`); `FeesCollected` widened with `totalAssets, totalShares, sharePrice`.
- *Breaking:* the `Fees` struct moved to `Types.sol` and gained `instantRedeemPremium`; single-asset `fulfillRedeem` removed (use `fulfillMultipleRedeems`).
- *Added:* instant redeem — `instantRedeem`, `previewInstantRedeem`, `maxInstantRedeem`, `getLiquidity`, `instantRedeemExitpoint`; emits `InstantRedeem` plus a standard ERC-4626 `Withdraw`.
- *Added:* `initializeV2(exitpoint, upgradeModule, freezeRegistry)` V1→V2 migration (reverts `NotMigratable` when there is no V1 state) and `cancelRedeemRequestByOperator(asset, controller)` for operators.

**CompliantUltraVault** *(new)* — `UltraVault` with a freeze gate (`COMPLIANCE_ROLE`): `freeze`/`unfreeze` (+ batch), `isFrozen`, and `forceBurn`. Honors both a local freeze list and an optional shared `IFreezeRegistry`; the local freeze list rejects the zero address, matching `SharedFreezeRegistry`.

**AllowlistUltraVault** *(new)* — `UltraVault` that restricts share ownership and redemption proceeds to an allowlist (`ALLOWLIST_ROLE`), enabled by default: `addToAllowlist`/`removeFromAllowlist` (+ batch), `setAllowlistEnabled`.

**BaseControlledAsyncRedeem**
- *Breaking:* `requestRedeem` consolidated to `requestRedeem(asset, shares, controller, owner, bool autoClaim)` and `cancelRedeemRequest` to `cancelRedeemRequest(asset, controller, receiver)` — all V1 overloads, the `…OfAsset` variants, and partial cancellation are removed.
- *Breaking:* redeem getters reduce to `getPendingRedeem(asset, controller)` / `getClaimableRedeem(asset, controller)`; the base-asset single-arg and the `…ForAsset` / `…RequestForAsset` variants are gone.
- *Breaking:* `convertToUnderlying` / `convertFromUnderlying` take an `Adjustment` argument and are now `public`.
- *Breaking:* upgrades delegated to an external module (`_authorizeUpgrade` requires `msg.sender == upgradeModule()`); rate-provider propose-accept replaced by the generic key-based `proposeAddressUpdate` / `acceptAddressUpdate`; access control is now plain `AccessControl`, `unpause` requires `UNPAUSER_ROLE`, and the lifecycle hooks were renamed/underscored (`beforeRequestRedeem`, `afterDeposit`, … removed).
- *Added:* `autoClaim` — fulfillment delivers assets to the controller in the same tx; queryable via `getAutoClaim(asset, controller)`. New `AddressUpdateProposed` / `AddressUpdated` events and `CannotSetSelfAsOperator` error.

**RedeemQueue** — queue state logic extracted into the external `RedeemQueueLib` (DELEGATECALL, cuts vault bytecode), now carrying the `autoClaim` flag; structs/errors moved to `Types.sol` / `IRedeemAccounting`.

**SharedFreezeRegistry** *(new)* — standalone `AccessControl` freeze list shared across vaults (`COMPLIANCE_ROLE`), exposing `IFreezeRegistry.isFrozen`; rejects the zero address.

**UltraVaultFactory** *(new)* — upgradeable CREATE2 deployer and version registry for vault proxies; `DEPLOYER_ROLE` deploys, `DEFAULT_ADMIN_ROLE` manages versions.

**Removed:** `UltraFeeder` (and `IUltraFeeder`) — the feeder vault is gone.

---

### Rate Providers

**UltraVaultRateProvider**
- *Breaking:* no longer upgradeable — deploy via `constructor(owner, baseAsset)`; the `initialize` / UUPS / timelock path and the old storage layout are removed (redeploy required).
- *Breaking:* renamed `decimals()` → `baseDecimals()` and `supportedAssets()` → `getAssetInfo()` (new return shape); the `AssetData` struct is removed.
- *Breaking:* per-asset conversion adjustments — `addAsset` gains `adjustmentRate`, `updateRateProvider(asset, isPegged, newProvider)` is re-signatured, and the `AssetAdded` / `RateProviderUpdated` events are reshaped.
- *Added:* `Adjustment`-aware `convertToUnderlying` / `convertFromUnderlying` overloads (the V1 two-arg overloads are retained), `updateAdjustmentRate` (capped at 1%), and `getSupportedAssets()`.

**New providers** *(all implement `IRateProvider`)*
- **AnyERC4626VaultRateProvider** — prices any ERC-4626 vault share against its underlying.
- **ChainlinkRateProvider** — converts via two Chainlink USD feeds with staleness/validity checks.
- **StableChainlinkRateProvider** — adds a 1:1 peg guard (max deviation ≤ 3%, owner-tunable).
- **ComposableRateProvider** — chains two providers through an intermediate asset (e.g. sUSDe → USDe → USDC); itself nestable.

---

### Oracles & Price Managers

**UltraVaultOracle** — rebuilt as a single deterministic share-price curve.
- *Breaking:* constructor is now `(owner, vault, initialPrice)` and enforces equal vault/asset decimals.
- *Breaking:* the imperative price API is removed (`setPrice(s)`, `scheduleLinearPriceUpdate(s)`, `getCurrentPrice`, `prices`, the `Price` struct); storage becomes an append-only update history and `PriceUpdated` is reshaped to `(startPrice, targetPrice, vestingDuration, startTimestamp)`.
- *Added:* `applyPriceUpdate(...)` plus views `currentSharePrice`, `historicalSharePrice`, `sharePriceAt`. Vesting is up-only and timestamps must be monotonic, enabling future-dated updates and deterministic cross-chain reads. A V1-compatible `getQuote` shim is retained.

**VaultPriceManager** — now a single-vault CCIP price orchestrator built on the new `BaseVaultPriceManager`.
- *Breaking:* constructor reshaped to `(oracle, vault, owner, ccipRouter, linkToken, initialNonce)`; multi-vault management (`addVault`, per-vault admins/limits), the instant/vesting batch setters, and `setOracle` are removed; price safety is now asymmetric `jumpUp` / `jumpDown` (the drawdown / high-water-mark concept is dropped).
- *Added:* `instantPriceUpdate` / `linearPriceUpdate` (with a `failOnPause` flag), a configurable apply `delay`, a CCIP destination registry, and LINK management. Updates apply locally and broadcast cross-chain atomically.

**RemoteVaultPriceManager** *(new)* — receives CCIP price updates on remote chains, guarded by a trusted-source allowlist and a strictly increasing nonce.

**PriceSyncMessage** *(new)* — shared wire format and codec for cross-chain price messages.

**Removed:** `OracleAdmin` — its role is absorbed by the price-manager admin model.

---

### Periphery & Infrastructure

**UltraVaultEthAdapter** *(new)* — upgradeable ETH⇄WETH adapter: `depositEth` (+ referral), `redeemEth`, `previewDepositEth`; pausable.

**UltraFrontendHelper** *(new)* — view helper aggregating vault state and deposit/redeem previews.

**Address management** — V1's per-field propose/accept flow is replaced by the generic key-based `AddressUpdatable` (keys defined in `AddressKeys`), covering the funds holder, oracle, rate provider, upgrade module, instant-redeem exitpoint, and freeze registry.

**TimelockedUpgradeModule** *(new)* — external 7-day upgrade gate that vaults delegate UUPS upgrades to (it reads `UPGRADER_ROLE` from the vault), replacing the in-tree `TimelockedUUPSUpgradeable`.

**Types** *(new)* — shared `Adjustment`, `Fees`, `Price`, `PendingRedeem`, and `ClaimableRedeem` moved out of individual interface files (import paths change).

**Roles** — added `UNPAUSER_ROLE`, `COMPLIANCE_ROLE`, `ALLOWLIST_ROLE`; removed `ORACLE_ADMIN_ROLE`; pause control split so unpausing requires `UNPAUSER_ROLE`.
