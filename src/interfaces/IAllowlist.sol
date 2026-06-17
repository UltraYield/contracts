// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IAllowlistEvents {
    event AccountAllowed(address indexed account);
    event AccountDisallowed(address indexed account);
    event AllowlistEnabledSet(bool enabled);
}

interface IAllowlistErrors {
    error NotAllowlisted(address account);
}

/// @title IAllowlist
/// @notice External interface for the deposit/mint allowlist gate
/// @dev Enforcement applies only to the depositor (msg.sender) on the deposit/mint path
interface IAllowlist is IAllowlistEvents, IAllowlistErrors {
    /// @notice Returns true if `account` is on the allowlist
    function isAllowed(address account) external view returns (bool);

    /// @notice Returns true if mandatory allowlist enforcement is currently active
    function isAllowlistEnabled() external view returns (bool);

    /// @notice Add `account` to the allowlist
    function addToAllowlist(address account) external;

    /// @notice Add multiple `accounts` to the allowlist
    function addToAllowlistBatch(address[] calldata accounts) external;

    /// @notice Remove `account` from the allowlist
    function removeFromAllowlist(address account) external;

    /// @notice Enable or disable mandatory allowlist enforcement on deposits/mints
    function setAllowlistEnabled(bool enabled) external;
}
