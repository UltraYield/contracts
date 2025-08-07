// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { VaultAdminControl } from "src/utils/VaultAdminControl.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IRedeemQueue, PendingRedeem, ClaimableRedeem } from "src/interfaces/IRedeemQueue.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.RedeemQueue")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_QUEUE_STORAGE_LOCATION = 0x38487c1eeb502ff9f43b364c26f88c9c1a7289f04ae6ea98e734b0ba2a992400;

/// @title RedeemQueue
/// @notice Contract to help manage redeems for async vaults
contract RedeemQueue {
    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.RedeemQueue
    struct Storage {
        mapping(address => mapping(address => PendingRedeem)) pendingRedeems;
        mapping(address => mapping(address => ClaimableRedeem)) claimableRedeems;
    }

    function _getRedeemQueueStorage() private pure returns (Storage storage $) {
        assembly {
            $.slot := ULTRA_QUEUE_STORAGE_LOCATION
        }
    }

    //////////////
    // Internal //
    //////////////

    function _getPendingRedeem(
        address user,
        address token
    ) internal view returns (PendingRedeem memory) {
        return _getRedeemQueueStorage().pendingRedeems[user][token];
    }

    function _getClaimableRedeem(
        address user,
        address token
    ) internal view returns (ClaimableRedeem memory) {
        return _getRedeemQueueStorage().claimableRedeems[user][token];
    }

    function _setPendingRedeem(
        address user,
        address token,
        PendingRedeem memory pendingRedeem
    ) internal {
        _getRedeemQueueStorage().pendingRedeems[user][token] = pendingRedeem;
    }

    function _setClaimableRedeem(
        address user,
        address token,
        ClaimableRedeem memory claimableRedeem
    ) internal {
        _getRedeemQueueStorage().claimableRedeems[user][token] = claimableRedeem;
    }
}
