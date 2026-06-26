// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UltraVault } from "src/vaults/UltraVault.sol";
import { ComplianceLib } from "src/utils/ComplianceLib.sol";
import { COMPLIANCE_ROLE } from "src/utils/Roles.sol";
import { IComplianceEvents, IComplianceErrors } from "src/interfaces/ICompliance.sol";
import { IFreezeRegistry } from "src/interfaces/IFreezeRegistry.sol";
import { FREEZE_REGISTRY_KEY } from "src/utils/AddressKeys.sol";

/// @title CompliantUltraVault
/// @notice UltraVault variant with the compliance suite: per-address freeze and forceBurn.
contract CompliantUltraVault is UltraVault, IComplianceEvents, IComplianceErrors {

    /////////////
    // Getters //
    /////////////

    /// @notice Returns true if `account` is frozen (effective state: local list OR shared registry)
    function isFrozen(address account) external view returns (bool) {
        return _isFrozen(account);
    }

    ////////////////
    // Compliance //
    ////////////////

    /// @notice Mark `account` as frozen
    function freeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.freeze(account);
    }

    /// @notice Mark multiple `accounts` as frozen
    function freezeBatch(address[] calldata accounts) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.freezeBatch(accounts);
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

    /// @dev Reverts if `account` is frozen.
    /// @dev Returns early on `address(0)` so callers don't need to special-case mints/burns.
    function _ensureNotFrozen(address account) internal view {
        if (account == address(0)) return;
        if (_isFrozen(account)) revert AddressFrozen(account);
    }

    /// @dev Bool sibling of `_ensureNotFrozen` for view-only eligibility checks (no revert reason).
    /// @dev Effective freeze = local list OR shared registry. The registry is authoritative and cannot
    ///      be overridden locally; when none is configured the registry lookup is skipped (local-only).
    ///      A configured registry is a hard dependency: a reverting `isFrozen` reverts the caller.
    function _isFrozen(address account) internal view returns (bool) {
        if (ComplianceLib._getComplianceStorage().frozen[account]) return true;
        address registry = _getCurrentAddress(FREEZE_REGISTRY_KEY);
        return registry != address(0) && IFreezeRegistry(registry).isFrozen(account);
    }

    /// @dev A frozen receiver can't receive minted shares, so its deposit/mint limit is 0.
    function _canReceiveShares(address account) internal view override returns (bool) {
        return !_isFrozen(account);
    }

    /// @dev A frozen controller can't instant-redeem (the gate rejects even a self-redeem).
    function _canInstantRedeem(address controller) internal view override returns (bool) {
        return !_isFrozen(controller);
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
        _ensureNotFrozen(msg.sender);
    }

    /// @dev Enforce freeze on receiver and controller before withdraw/redeem
    function _beforeWithdraw(
        address /* _asset */,
        uint256 /* assets */,
        uint256 /* shares */,
        address receiver,
        address controller
    ) internal view override {
        _ensureNotFrozen(receiver);
        if (controller != receiver) _ensureNotFrozen(controller);
    }

    /// @dev Enforce freeze on receiver and controller before an instant redeem
    function _beforeInstantRedeem(address receiver, address controller) internal view override {
        _ensureNotFrozen(receiver);
        if (controller != receiver) _ensureNotFrozen(controller);
    }

    /// @dev Block frozen addresses from cancelling pending redeems
    /// @dev Receiver is gated by `_update` on the share transfer back from the vault.
    function _handleRedeemRequestCancelation(
        address _asset,
        uint256 shares,
        address controller,
        address receiver
    ) internal override {
        _ensureNotFrozen(controller);
        super._handleRedeemRequestCancelation(_asset, shares, controller, receiver);
    }

    /// @dev Gates share transfers and mints.
    /// @dev Burns (`to == 0`) skip the from-side check so `forceBurn` can destroy a frozen address's shares.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            _ensureNotFrozen(from);
        }
        _ensureNotFrozen(to);
        super._update(from, to, value);
    }
}
