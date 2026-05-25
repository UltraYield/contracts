// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/// @title PriceSyncMessage
/// @notice Wire format for a cross-chain price update broadcast.
/// @dev    Sent by the main-chain `VaultPriceManager` to every active destination
///         and consumed by `RemoteVaultPriceManager` (added in PR #2). Both sides
///         import this single struct + lib so the encoding stays in lockstep.
struct PriceSyncMessage {
    uint64 nonce; // 16
    uint64 mainScheduleTimestamp; // +32=48
    uint88 startPrice; // +88=136
    uint88 targetPrice; // +88=224
    uint40 vestingDuration; // +32=256
    bool mainPaused;
}

library PriceSyncMessageLib {
    function encode(PriceSyncMessage memory message) internal pure returns (bytes memory) {
        return abi.encode(message);
    }

    function decode(bytes memory data) internal pure returns (PriceSyncMessage memory) {
        return abi.decode(data, (PriceSyncMessage));
    }
}
