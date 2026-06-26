// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { COMPLIANCE_ROLE } from "src/utils/Roles.sol";
import { IComplianceEvents } from "src/interfaces/ICompliance.sol";
import { IFreezeRegistry } from "src/interfaces/IFreezeRegistry.sol";

/// @title SharedFreezeRegistry
/// @notice Immutable, standalone registry of frozen addresses shared across compliant vaults.
/// @notice A restricted address is added once here and honored by every vault pointed at it.
/// @dev Vaults OR this registry's `isFrozen` into their own local freeze list (additive) and never
///      write here. Management is gated by COMPLIANCE_ROLE. The contract is not upgradeable, so
///      replacing it means deploying a new registry and re-pointing vaults.
contract SharedFreezeRegistry is AccessControl, IFreezeRegistry, IComplianceEvents {

    /// @notice Thrown when the admin address is zero at construction
    error ZeroAdminAddress();

    /// @notice Thrown when freezing or unfreezing the zero address
    /// @dev The zero address is the ERC20 mint/burn sentinel and must never be frozen — vaults OR
    ///      this registry into their checks, so a frozen zero address could brick mint/burn flows.
    error ZeroAddress();

    /// @dev Frozen state per address
    mapping(address => bool) private _frozen;

    /// @param admin Address granted DEFAULT_ADMIN_ROLE; it administers COMPLIANCE_ROLE membership
    constructor(address admin) {
        require(admin != address(0), ZeroAdminAddress());
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /////////////
    // Getters //
    /////////////

    /// @inheritdoc IFreezeRegistry
    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }

    ////////////////
    // Compliance //
    ////////////////

    /// @notice Mark `account` as frozen
    function freeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        _freeze(account);
    }

    /// @notice Mark multiple `accounts` as frozen
    function freezeBatch(address[] calldata accounts) external onlyRole(COMPLIANCE_ROLE) {
        for (uint256 i; i < accounts.length; i++) {
            _freeze(accounts[i]);
        }
    }

    /// @notice Unmark `account` as frozen
    function unfreeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        require(account != address(0), ZeroAddress());
        if (_frozen[account]) {
            _frozen[account] = false;
            emit AccountUnfrozen(account);
        }
    }

    /// @dev Idempotent freeze — only writes/emits on an actual state change
    function _freeze(address account) private {
        require(account != address(0), ZeroAddress());
        if (!_frozen[account]) {
            _frozen[account] = true;
            emit AccountFrozen(account);
        }
    }
}
