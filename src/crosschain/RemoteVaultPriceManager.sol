// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { CCIPReceiver } from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import { BaseVaultPriceManager } from "src/crosschain/BaseVaultPriceManager.sol";
import { PriceSyncMessage, PriceSyncMessageLib } from "src/crosschain/PriceSyncMessage.sol";
import { IPausable } from "src/interfaces/IPausable.sol";

/// @title RemoteVaultPriceManager
/// @notice Destination-chain manager: applies price updates broadcast over CCIP into its
///         local oracle. Each message is guarded by the CCIP router, a trusted
///         `(sourceChainSelector, sender)` allowlist, and a strictly-increasing nonce.
contract RemoteVaultPriceManager is BaseVaultPriceManager, CCIPReceiver {
    ////////////
    // Events //
    ////////////

    event TrustedSourceUpdated(uint64 sourceChainSelector, address sender);
    event PriceSynced(
        uint64 indexed nonce,
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 startTimestamp
    );
    /// @notice Emitted when a broadcast's pause flag pauses the local vault. `nonce` is the
    ///         carrying message's nonce (may be stale — pause is processed out of order).
    event PauseSynced(uint64 nonce);
    /// @notice Emitted when a delivered price curve is dropped as stale/out-of-order. The
    ///         message is still accepted (not reverted) so any pause flag it carries applies.
    event StaleUpdateSkipped(uint64 received, uint64 lastSeen);

    ////////////
    // Errors //
    ////////////

    error UntrustedSource(uint64 sourceChainSelector, address sender);

    /////////////
    // Storage //
    /////////////

    /// @notice The only source accepted for inbound messages.
    uint64 public trustedSourceChainSelector;
    address public trustedSender;

    /// @notice Highest nonce applied so far; inbound nonce must strictly exceed it.
    uint64 public lastNonce;

    /////////////////
    // Constructor //
    /////////////////

    /// @param _initialNonce Starting nonce floor; messages must carry a strictly greater
    ///        nonce. On a redeploy, set this to the source's current `broadcastNonce` to
    ///        reject stale re-deliveries (0 for a fresh deploy).
    constructor(
        address _oracle,
        address _vault,
        address _owner,
        address _ccipRouter,
        uint64 _initialNonce
    ) BaseVaultPriceManager(_oracle, _vault, _owner) CCIPReceiver(_ccipRouter) {
        lastNonce = _initialNonce;
    }

    /////////////////////
    // Config (owner)  //
    /////////////////////

    /// @notice Set the trusted broadcast source. Until set, all messages are rejected.
    function setTrustedSource(uint64 sourceChainSelector, address sender) external onlyOwner {
        require(sender != address(0), ZeroAddress());
        trustedSourceChainSelector = sourceChainSelector;
        trustedSender = sender;
        emit TrustedSourceUpdated(sourceChainSelector, sender);
    }

    //////////////////
    // CCIP Receive //
    //////////////////

    /// @inheritdoc CCIPReceiver
    /// @dev The pause flag and the price curve are handled with different ordering rules:
    ///
    ///      - **Pause** is honored regardless of nonce. An earlier breaching broadcast can be
    ///        delivered after a newer one (CCIP does not guarantee ordering); processing the
    ///        pause before the nonce gate — and never reverting a stale message — guarantees a
    ///        propagated pause is never dropped. It is idempotent (no-op if already paused).
    ///      - **Price curve** is strictly nonce-ordered. A stale/duplicate/out-of-order curve
    ///        is skipped (not reverted) so the array stays monotonic and no update is
    ///        double-applied, while any pause the same message carried still lands.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        if (message.sourceChainSelector != trustedSourceChainSelector || sender != trustedSender) {
            revert UntrustedSource(message.sourceChainSelector, sender);
        }

        PriceSyncMessage memory psm = PriceSyncMessageLib.decode(message.data);

        // Pause first, independent of nonce ordering. Idempotent.
        if (psm.pauseRequired && !IPausable(vault).paused()) {
            IPausable(vault).pause();
            emit PauseSynced(psm.nonce);
        }

        // Nonce-ordered price curve. Stale/out-of-order curves are dropped without reverting,
        // so the pause above (which may ride a stale message) persists.
        if (psm.nonce <= lastNonce) {
            emit StaleUpdateSkipped(psm.nonce, lastNonce);
            return;
        }
        lastNonce = psm.nonce;

        // Applied verbatim; a late update converges via the oracle's read-time interpolation.
        // failOnPause is false: an inbound broadcast must always succeed.
        _applyUpdate(
            uint256(psm.startPrice),
            uint256(psm.targetPrice),
            uint256(psm.vestingDuration),
            uint256(psm.startTimestamp),
            false
        );

        emit PriceSynced(
            psm.nonce,
            uint256(psm.startPrice),
            uint256(psm.targetPrice),
            uint256(psm.vestingDuration),
            uint256(psm.startTimestamp)
        );
    }
}
