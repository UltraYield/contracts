// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UltraVault } from "src/vaults/UltraVault.sol";
import { ComplianceLib } from "src/utils/ComplianceLib.sol";
import { COMPLIANCE_ROLE } from "src/utils/Roles.sol";
import { IComplianceEvents, IComplianceErrors } from "src/interfaces/ICompliance.sol";

/// @title CompliantUltraVault
/// @notice UltraVault variant with the compliance suite: per-address blocklist, freeze, and forceBurn.
contract CompliantUltraVault is UltraVault, IComplianceEvents, IComplianceErrors {

    ////////////////
    // Compliance //
    ////////////////

    /// @notice Get blocklist and freeze status for `account`
    /// @return blocked True if `account` is blocklisted
    /// @return frozen True if `account` is frozen
    function restrictionStatus(address account) external view returns (bool blocked, bool frozen) {
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        blocked = $.blocklisted[account];
        frozen = $.frozen[account];
    }

    /// @notice Add `account` to the blocklist
    function addToBlocklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.addToBlocklist(account);
    }

    /// @notice Add multiple `accounts` to the blocklist
    function addToBlocklistBatch(address[] calldata accounts) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.addToBlocklistBatch(accounts);
    }

    /// @notice Remove `account` from the blocklist
    function removeFromBlocklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.removeFromBlocklist(account);
    }

    /// @notice Mark `account` as frozen
    function freeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.freeze(account);
    }

    /// @notice Unmark `account` as frozen
    function unfreeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.unfreeze(account);
    }

    /// @notice Burn `amount` shares from `target`'s wallet balance.
    /// @dev Only affects `balanceOf(target)`; pending and claimable redeems are untouched.
    function forceBurn(address target, uint256 amount) external onlyRole(COMPLIANCE_ROLE) {
        _burn(target, amount);
        emit ForceBurned(target, amount);
    }

    /// @dev Reverts if `account` is blocklisted or frozen.
    /// @dev Returns early on `address(0)` so callers don't need to special-case mints/burns.
    function _ensureNotRestricted(address account) internal view {
        if (account == address(0)) return;
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        if ($.blocklisted[account]) revert AddressBlocklisted(account);
        if ($.frozen[account]) revert AddressFrozen(account);
    }

    /// @dev Bool sibling of `_ensureNotRestricted` for view-only eligibility checks (no revert reason).
    function _isRestricted(address account) internal view returns (bool) {
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        return $.blocklisted[account] || $.frozen[account];
    }

    /// @dev A restricted receiver can't receive minted shares, so its deposit/mint limit is 0.
    function _canReceiveShares(address account) internal view override returns (bool) {
        return !_isRestricted(account);
    }

    /// @dev A restricted controller can't instant-redeem (the gate rejects even a self-redeem).
    function _canInstantRedeem(address controller) internal view override returns (bool) {
        return !_isRestricted(controller);
    }

    ////////////////////
    // Hook Overrides //
    ////////////////////

    /// @dev Gate the depositor (msg.sender) on every deposit/mint path
    function _beforeDeposit(
        address /* _asset */,
        uint256 /* assets */,
        uint256 /* shares */,
        address /* receiver */
    ) internal view override {
        _ensureNotRestricted(msg.sender);
    }

    /// @dev Enforce restrictions on receiver and controller before withdraw/redeem
    function _beforeWithdraw(
        address /* _asset */,
        uint256 /* assets */,
        uint256 /* shares */,
        address receiver,
        address controller
    ) internal view override {
        _ensureNotRestricted(receiver);
        if (controller != receiver) _ensureNotRestricted(controller);
    }

    /// @dev Enforce restrictions on receiver and controller before an instant redeem
    function _beforeInstantRedeem(address receiver, address controller) internal view override {
        _ensureNotRestricted(receiver);
        if (controller != receiver) _ensureNotRestricted(controller);
    }

    /// @dev Block restricted addresses from cancelling pending redeems
    /// @dev Receiver is gated by `_update` on the share transfer back from the vault.
    function _handleRedeemRequestCancelation(
        address _asset,
        uint256 shares,
        address controller,
        address receiver
    ) internal override {
        _ensureNotRestricted(controller);
        super._handleRedeemRequestCancelation(_asset, shares, controller, receiver);
    }

    /// @dev Gates share transfers and mints.
    /// @dev Burns (`to == 0`) skip the from-side check so `forceBurn` can destroy a restricted address's shares.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            _ensureNotRestricted(from);
        }
        _ensureNotRestricted(to);
        super._update(from, to, value);
    }
}
