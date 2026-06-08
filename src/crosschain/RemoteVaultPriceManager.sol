// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { CCIPReceiver } from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import { BaseVaultPriceManager } from "src/crosschain/BaseVaultPriceManager.sol";
import { PriceSyncMessage, PriceSyncMessageLib } from "src/crosschain/PriceSyncMessage.sol";

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

    ////////////
    // Errors //
    ////////////

    error UntrustedSource(uint64 sourceChainSelector, address sender);
    error StaleNonce(uint64 received, uint64 lastSeen);

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
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        if (message.sourceChainSelector != trustedSourceChainSelector || sender != trustedSender) {
            revert UntrustedSource(message.sourceChainSelector, sender);
        }

        PriceSyncMessage memory psm = PriceSyncMessageLib.decode(message.data);
        if (psm.nonce <= lastNonce) {
            revert StaleNonce(psm.nonce, lastNonce);
        }
        lastNonce = psm.nonce;

        // Applied verbatim; a late update converges via the oracle's read-time interpolation.
        _applyUpdate(
            uint256(psm.startPrice),
            uint256(psm.targetPrice),
            uint256(psm.vestingDuration),
            uint256(psm.startTimestamp)
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
