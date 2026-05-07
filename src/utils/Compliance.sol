// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IComplianceEvents, IComplianceErrors } from "src/interfaces/ICompliance.sol";
import { ComplianceLib, COMPLIANCE_STORAGE_LOCATION } from "src/utils/ComplianceLib.sol";
import { COMPLIANCE_ROLE } from "src/utils/Roles.sol";

/// @title Compliance
/// @notice Base contract providing per-address blocklist and freeze controls.
/// @dev Heavy admin/read logic is delegated to `ComplianceLib` (external library)
///      to keep host-contract bytecode small. The hot-path `_ensureNotRestricted`
///      is kept inline here to avoid delegatecall overhead on every transfer.
abstract contract Compliance is AccessControlUpgradeable, IComplianceEvents, IComplianceErrors {
    /////////////
    // Getters //
    /////////////

    /// @notice Get blocklist and freeze status for `account`
    /// @return blocked True if `account` is blocklisted
    /// @return frozen True if `account` is frozen
    function restrictionStatus(address account) external view returns (bool blocked, bool frozen) {
        ComplianceLib.Storage storage $ = _getComplianceStorage();
        blocked = $.blocklisted[account];
        frozen = $.frozen[account];
    }

    /////////////////////
    // Admin Functions //
    /////////////////////

    function blocklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.blocklist(account);
    }

    function unblocklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.unblocklist(account);
    }

    function freeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.freeze(account);
    }

    function unfreeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.unfreeze(account);
    }

    //////////////
    // Internal //
    //////////////

    /// @dev Reverts if `account` is blocklisted or frozen.
    /// @dev Returns early on `address(0)` so callers don't need to special-case mints/burns.
    function _ensureNotRestricted(address account) internal view {
        if (account == address(0)) return;
        ComplianceLib.Storage storage $ = _getComplianceStorage();
        if ($.blocklisted[account]) revert AddressBlocklisted(account);
        if ($.frozen[account]) revert AddressFrozen(account);
    }

    function _getComplianceStorage() private pure returns (ComplianceLib.Storage storage $) {
        assembly { 
            $.slot := COMPLIANCE_STORAGE_LOCATION 
        }
    }
}
