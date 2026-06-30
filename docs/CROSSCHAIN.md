# Cross-Chain Pricing (CCIP)

## Why cross-chain pricing exists

An UltraYield vault may be deployed on several chains while one share price must govern all of them. Rather than running an independent price feed per chain (which would drift), the system authors **one canonical share price on a main chain** and mirrors it to every remote chain over Chainlink CCIP.

The trick that makes this safe is determinism: the price is not a stored number that must arrive intact, it is a curve. Each update carries a `startTimestamp`, `startPrice`, `targetPrice`, and `vestingDuration`, and the oracle (`UltraVaultOracle`) interpolates the live price as a pure function of `block.timestamp`. The same update applied verbatim on any chain therefore yields the same price at the same wall-clock instant. A broadcast that arrives late still converges onto the identical curve. See [Oracles](ORACLES.md) for the curve model.

## Architecture

The price itself lives in an `IUltraVaultOracle` (one per chain); the managers are thin authority/transport layers around `oracle.applyPriceUpdate(...)`. Both managers extend `BaseVaultPriceManager`, which holds the oracle/vault binding, the admin set, the asymmetric jump limits, and the shared apply path.

- **Main chain — `VaultPriceManager`** (`src/oracles/VaultPriceManager.sol`): the price-authoring + broadcast orchestrator. It is the CCIP *sender*.
- **Remote chains — `RemoteVaultPriceManager`** (`src/crosschain/RemoteVaultPriceManager.sol`): a CCIP *receiver* (`is CCIPReceiver`) that applies inbound updates to its local oracle.

```mermaid
flowchart LR
    admin([Admin / Owner]) -->|instantPriceUpdate / linearPriceUpdate| VPM[VaultPriceManager<br/>main chain]
    VPM -->|applyPriceUpdate| O1[(UltraVaultOracle<br/>main)]
    VPM -->|ccipSend per active dest| R[Chainlink CCIP Router]
    R --> RM1[RemoteVaultPriceManager<br/>chain A]
    R --> RM2[RemoteVaultPriceManager<br/>chain B]
    RM1 -->|applyPriceUpdate| O2[(UltraVaultOracle A)]
    RM2 -->|applyPriceUpdate| O3[(UltraVaultOracle B)]
```

## Price-propagation flow

`instantPriceUpdate` and `linearPriceUpdate` apply locally first, then broadcast, in a single transaction. It is **all-or-nothing**: `ccipSend` is called with no try/catch, so any leg that reverts unwinds the local update too — the main chain can never end up applied while a broadcast was silently lost.

```mermaid
sequenceDiagram
    participant A as Admin/Owner
    participant V as VaultPriceManager (main)
    participant O as Oracle (main)
    participant C as CCIP Router
    participant R as RemoteVaultPriceManager
    participant RO as Oracle (remote)

    A->>V: instantPriceUpdate(newPrice, failOnPause) / linearPriceUpdate(newPrice, duration, failOnPause)
    Note over V: startTimestamp = block.timestamp + delay
    V->>O: applyPriceUpdate(...) (via _applyUpdate)
    loop each active destination
        V->>C: ccipSend(selector, PriceSyncMessage) — fee in LINK
        Note over V: emit Broadcast(selector, nonce, messageId)
    end
    C-->>R: _ccipReceive(message)
    Note over R: check trusted source + nonce > lastNonce
    R->>RO: applyPriceUpdate(...) (failOnPause = false)
    Note over R: emit PriceSynced(nonce, ...)
```

`linearPriceUpdate` sets `startPrice = oracle.sharePriceAt(startTimestamp)` so the new vest continues smoothly from the projected curve; `instantPriceUpdate` reuses `newPrice` for both start and target with `vestingDuration = 0`.

## `PriceSyncMessage` — wire format

Both sides import one struct + codec (`src/crosschain/PriceSyncMessage.sol`) so encoding stays in lockstep:

```solidity
struct PriceSyncMessage {
    uint64 nonce;
    uint88 startPrice;
    uint88 targetPrice;
    uint40 vestingDuration;
    uint40 startTimestamp;
}
```

`PriceSyncMessageLib.encode` / `decode` are plain `abi.encode` / `abi.decode`. The narrow widths are not for packing — the sender bounds-checks every field against its type max in `_broadcastUpdate` and reverts `Overflow()` rather than truncating, so the remote decode is lossless.

## Security: trusted source + monotonic nonce

The receive path has three independent guards:

- **CCIP router gate** — `CCIPReceiver` restricts `ccipReceive` to the configured router; `_ccipReceive` is unreachable otherwise.
- **Trusted-source allowlist** — exactly one `(trustedSourceChainSelector, trustedSender)` pair is accepted; anything else reverts `UntrustedSource`. Set via owner-only `setTrustedSource`; until set, every message is rejected (`trustedSender` defaults to the zero address).
- **Strictly-increasing nonce** — `lastNonce` is a high-water mark; an inbound `nonce <= lastNonce` reverts `StaleNonce`. The sender stamps `++broadcastNonce` on each broadcast, so nonces are monotone on both ends. CCIP does not guarantee ordered delivery, so out-of-order or replayed messages are dropped; skipping an intermediate update is harmless because each message carries the absolute target curve, not a delta.

Nonce continuity across redeploys is operator-managed through the `_initialNonce` constructor arg on both ends (seed a remote's `lastNonce` to the source's current `broadcastNonce`; 0 for a fresh deploy).

## Operational details

- **`failOnPause`** — on the main chain the caller chooses revert-vs-pause when an update breaches the `jumpUp`/`jumpDown` limits (`UpdateWouldPause` if true). On the remote, `_applyUpdate` is called with `failOnPause = false` hardcoded: an authentic broadcast must always land, so a limit breach pauses the local vault instead of reverting the receive. A remote evaluates its *own* `limits`, so it can pause locally even when the main chain applied cleanly.
- **Apply delay** — updates are future-dated to `block.timestamp + delay`, bounded by `MIN_DELAY` (15m) and `MAX_DELAY` (3h), default `DEFAULT_DELAY` (1h), set via `setDelay`. The lead time gives CCIP room to deliver before the curve activates.
- **Destination registry** — owners manage targets with `addDestination` / `removeDestination` / `updateDestinationConfig`; `setDestinationActive` is an admin-or-owner escape hatch to deactivate a stuck destination. `_broadcastUpdate` skips any destination whose `active` flag is false, and the broadcast still succeeds for the rest.
- **LINK management** — the constructor pre-approves `type(uint256).max` LINK to the router so each `ccipSend` can pull its fee; the contract is funded with LINK and `withdrawLink` (owner) recovers it.

## Roles

- **Owner** (both managers, `Ownable2Step`): shared config from `BaseVaultPriceManager` — `updateLimits`, `addAdmin`/`removeAdmin`, `claimOracleOwnership`. The main-chain `VaultPriceManager` adds `setDelay`, destination membership (`addDestination` / `removeDestination` / `updateDestinationConfig`), and `withdrawLink`; the remote `RemoteVaultPriceManager` adds `setTrustedSource`.
- **Admin** (`isAdmin`, via `onlyAdminOrOwner`): operational price pushes — `instantPriceUpdate`, `linearPriceUpdate`, `setDestinationActive`.
- The oracle's own owner (the one allowed to call `applyPriceUpdate`) is the manager itself, established by transferring oracle ownership to it and calling `claimOracleOwnership()`.
