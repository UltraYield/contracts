// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UltraVault } from "src/vaults/UltraVault.sol";
import { ComplianceLib } from "src/utils/ComplianceLib.sol";
import { IAllowlistEvents, IAllowlistErrors } from "src/interfaces/IAllowlist.sol";
import { ALLOWLIST_ROLE } from "src/utils/Roles.sol";

/// @title AllowlistUltraVault
/// @notice UltraVault variant that restricts deposits and mints to an allowlisted set of depositors.
/// @dev The gate checks only the depositor (msg.sender) on the deposit/mint path. Receivers, redeems,
///      transfers, and the owner-only `setupInitialBalances` bootstrap are intentionally unaffected.
/// @dev Allowlist state lives in the shared `ComplianceLib` namespace (`ultrayield.storage.Compliance`),
///      so it is canonical across variants and upgrades. Enforcement is ON by default via the
///      zero-value `allowlistDisabled` flag — a fresh deployment fails safe.
contract AllowlistUltraVault is UltraVault, IAllowlistEvents, IAllowlistErrors {

    /////////////
    // Getters //
    /////////////

    /// @notice Returns true if `account` is on the allowlist
    function isAllowed(address account) public view returns (bool) {
        return ComplianceLib._getComplianceStorage().allowlisted[account];
    }

    /// @notice Returns true if mandatory allowlist enforcement is currently active
    function isAllowlistEnabled() public view returns (bool) {
        return !ComplianceLib._getComplianceStorage().allowlistDisabled;
    }

    ///////////////
    // Allowlist //
    ///////////////

    /// @notice Add a single `account` to the allowlist
    function addToAllowlist(address account) external onlyRole(ALLOWLIST_ROLE) {
        ComplianceLib.addToAllowlist(account);
    }

    /// @notice Add multiple `accounts` to the allowlist
    function addToAllowlistBatch(address[] calldata accounts) external onlyRole(ALLOWLIST_ROLE) {
        ComplianceLib.addToAllowlistBatch(accounts);
    }

    /// @notice Remove a single `account` from the allowlist
    function removeFromAllowlist(address account) external onlyRole(ALLOWLIST_ROLE) {
        ComplianceLib.removeFromAllowlist(account);
    }

    /// @notice Enable or disable mandatory allowlist enforcement on deposits/mints
    /// @dev Owner-only master switch; enforcement is ON by default. Works while paused so the
    ///      allowlist can be configured during the initial paused setup window.
    function setAllowlistEnabled(bool enabled) external onlyOwner {
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        bool disabled = !enabled;
        if ($.allowlistDisabled != disabled) {
            $.allowlistDisabled = disabled;
            emit AllowlistEnabledSet(enabled);
        }
    }

    ////////////////////
    // Hook Overrides //
    ////////////////////

    /// @dev Gate the depositor (msg.sender) before every deposit/mint
    function _beforeDeposit(
        address /* _asset */,
        uint256 /* assets */,
        uint256 /* shares */,
        address /* receiver */
    ) internal view override {
        _ensureAllowlisted(msg.sender);
    }

    //////////////////////
    // Internal helpers //
    //////////////////////

    /// @dev Reverts if enforcement is enabled and `account` is not allowlisted
    function _ensureAllowlisted(address account) internal view {
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        if (!$.allowlistDisabled && !$.allowlisted[account]) {
            revert NotAllowlisted(account);
        }
    }
}
