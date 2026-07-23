// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/// @title PriceSyncMessage
/// @notice Wire format for a cross-chain price update broadcast.
/// @dev    Sent by the main-chain `VaultPriceManager` to every active destination
///         and consumed by `RemoteVaultPriceManager`. Both sides import this single
///         struct + lib so the encoding stays in lockstep.
/// @dev    `pauseRequired` carries the main chain's pause decision so a remote pauses
///         even when its own limits/oracle state would not trigger locally. It is
///         honored independently of the nonce ordering on the receiver (see
///         `RemoteVaultPriceManager`), so an out-of-order or stale broadcast can still
///         propagate a pause that must not be dropped.
struct PriceSyncMessage {
    uint64 nonce;
    uint88 startPrice;
    uint88 targetPrice;
    uint40 vestingDuration;
    uint40 startTimestamp;
    bool pauseRequired;
}

library PriceSyncMessageLib {
    function encode(PriceSyncMessage memory message) internal pure returns (bytes memory) {
        return abi.encode(message);
    }

    function decode(bytes memory data) internal pure returns (PriceSyncMessage memory) {
        return abi.decode(data, (PriceSyncMessage));
    }
}
