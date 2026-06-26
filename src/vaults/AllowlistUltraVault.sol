// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UltraVault } from "src/vaults/UltraVault.sol";
import { ComplianceLib } from "src/utils/ComplianceLib.sol";
import { IAllowlistEvents, IAllowlistErrors } from "src/interfaces/IAllowlist.sol";
import { ALLOWLIST_ROLE } from "src/utils/Roles.sol";

/// @title AllowlistUltraVault
/// @notice UltraVault variant that confines share ownership and redemption proceeds to an allowlisted set of wallets.
/// @dev The depositor (msg.sender) is gated on the deposit/mint path. Separately, every share
///      movement is gated on its recipient via `_update` (the deposit/mint receiver, peer transfers,
///      the cancel-redeem share return, the owner bootstrap, and the fee-share mint) — only burns and
///      the vault itself are exempt, so shares can only ever land on allowlisted wallets. Redeemed
///      assets are gated on `receiver` when it differs from the controller (self-exit stays open).
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

    /// @notice Enable or disable mandatory allowlist enforcement across all gated flows
    /// @dev Owner-only master switch; enforcement is ON by default. When disabled, every
    ///      `_ensureAllowlisted` check is lifted — deposits/mints, share transfers, and non-self
    ///      redemption recipients are all ungated until re-enabled.
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

    /// @dev Gate the depositor (msg.sender) before every deposit/mint.
    /// @dev The receiver is gated separately by `_update` on the share mint.
    function _beforeDeposit(
        address /* _asset */,
        uint256 /* assets */,
        uint256 /* shares */,
        address /* receiver */
    ) internal view override {
        _ensureAllowlisted(msg.sender);
    }

    /// @dev Gate the asset recipient when it differs from the controller (self-exit stays open).
    function _beforeWithdraw(
        address /* _asset */,
        uint256 /* assets */,
        uint256 /* shares */,
        address receiver,
        address controller
    ) internal view override {
        if (receiver != controller) _ensureAllowlisted(receiver);
    }

    /// @dev Gate the asset recipient when it differs from the controller (self-exit stays open).
    function _beforeInstantRedeem(address receiver, address controller) internal view override {
        if (receiver != controller) _ensureAllowlisted(receiver);
    }

    /// @dev Gate the recipient on every share movement except burns (`to == 0`) and redeem-request
    ///      escrow into the vault itself (`to == this`). All other recipients — including the fee
    ///      recipient and bootstrap users — must be allowlisted (ensured operationally).
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && to != address(this)) {
            _ensureAllowlisted(to);
        }
        super._update(from, to, value);
    }

    //////////////////////
    // Internal helpers //
    //////////////////////

    /// @dev True if enforcement is disabled or `account` is on the allowlist
    function _passesAllowlist(address account) internal view returns (bool) {
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        return $.allowlistDisabled || $.allowlisted[account];
    }

    /// @dev Reverts if enforcement is enabled and `account` is not allowlisted
    function _ensureAllowlisted(address account) internal view {
        if (!_passesAllowlist(account)) revert NotAllowlisted(account);
    }

    /// @dev A non-allowlisted receiver can't receive minted shares, so its deposit/mint limit is 0.
    function _canReceiveShares(address account) internal view override returns (bool) {
        return _passesAllowlist(account);
    }
}
