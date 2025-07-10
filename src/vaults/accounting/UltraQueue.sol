// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { VaultAdminControl } from "../../utils/VaultAdminControl.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { PendingRedeem, ClaimableRedeem } from "../../interfaces/IUltraQueue.sol";

/**
 * @title VaultPriceManager
 * @notice Contract managing vault price updates with limits
 * @dev Has built in safety mechanisms to pause vault upon sudden moves
 */
contract UltraQueue is VaultAdminControl, Initializable {

    mapping(address => mapping(address => mapping(address => PendingRedeem))) public pendingRedeems;
    mapping(address => mapping(address => mapping(address => ClaimableRedeem))) public claimableRedeems;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        initOwner(_owner);
    }

    function getPendingRedeem(
        address user, 
        address vault, 
        address token
    ) external view returns (PendingRedeem memory) {
        return pendingRedeems[user][vault][token];
    }

    function getClaimableRedeem(
        address user, 
        address vault, 
        address token
    ) external view returns (ClaimableRedeem memory) {
        return claimableRedeems[user][vault][token];
    }

    function setPendingRedeem(
        address user, 
        address vault, 
        address token,
        PendingRedeem memory pendingRedeem
    ) external onlyAdminOrOwner(vault) {
        pendingRedeems[user][vault][token] = pendingRedeem;
    }

    function setClaimableRedeem(
        address user, 
        address vault, 
        address token,
        ClaimableRedeem memory claimableRedeem
    ) external onlyAdminOrOwner(vault) {
        claimableRedeems[user][vault][token] = claimableRedeem;
    }
}
