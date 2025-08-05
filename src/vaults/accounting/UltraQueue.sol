// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { VaultAdminControl } from "src/utils/VaultAdminControl.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IUltraQueue, PendingRedeem, ClaimableRedeem } from "src/interfaces/IUltraQueue.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraQueue")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_QUEUE_STORAGE_LOCATION = 0x38487c1eeb502ff9f43b364c26f88c9c1a7289f04ae6ea98e734b0ba2a992400;

/// @title UltraQueue
/// @notice Contract to help manage redeems for async vaults
contract UltraQueue is VaultAdminControl, UUPSUpgradeable, IUltraQueue {
    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraQueue
    struct Storage {
        mapping(address => mapping(address => mapping(address => PendingRedeem))) pendingRedeems;
        mapping(address => mapping(address => mapping(address => ClaimableRedeem))) claimableRedeems;
    }

    function _getUltraQueueStorage() private pure returns (Storage storage $) {
        assembly {
            $.slot := ULTRA_QUEUE_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        __UUPSUpgradeable_init();
        initOwner(_owner);
    }

    ////////////
    // Public //
    ////////////

    function getPendingRedeem(
        address user, 
        address vault, 
        address token
    ) external view returns (PendingRedeem memory) {
        return _getUltraQueueStorage().pendingRedeems[user][vault][token];
    }

    function getClaimableRedeem(
        address user, 
        address vault, 
        address token
    ) external view returns (ClaimableRedeem memory) {
        return _getUltraQueueStorage().claimableRedeems[user][vault][token];
    }

    function setPendingRedeem(
        address user, 
        address vault, 
        address token,
        PendingRedeem memory pendingRedeem
    ) external onlyAdminOrOwner(vault) {
        _getUltraQueueStorage().pendingRedeems[user][vault][token] = pendingRedeem;
    }

    function setClaimableRedeem(
        address user, 
        address vault, 
        address token,
        ClaimableRedeem memory claimableRedeem
    ) external onlyAdminOrOwner(vault) {
        _getUltraQueueStorage().claimableRedeems[user][vault][token] = claimableRedeem;
    }

    //////////////////////
    // UUPS Upgradeable //
    //////////////////////

    /// @notice UUPS Upgradable access authorization
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
