// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/// @title IFreezeRegistry
/// @notice Minimal read interface a vault depends on to consult the shared freeze registry.
interface IFreezeRegistry {
    /// @notice Returns true if `account` is frozen in the shared registry
    function isFrozen(address account) external view returns (bool);
}
