// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { IPriceSourceV1 } from "src/legacy/v1/interfaces/IPriceSourceV1.sol";

/// @notice A snapshot of an oracle price update that has been recorded but may
///         not yet be effective. Returned by writes and by `pendingUpdate` /
///         `lastEffectiveUpdate` views.
struct RecordedUpdate {
    uint256 startPrice;
    uint256 targetPrice;
    uint256 vestingDuration;
    uint256 effectiveAt;
}

/// @title IUltraVaultOracle
/// @notice Interface for push-based price oracle
/// @dev Extends IPriceSource with price setting capabilities
/// @dev Also implements IPriceSourceV1 for backwards compatibility with V1 vaults
interface IUltraVaultOracle is IPriceSource, IPriceSourceV1 {
    ////////////
    // Events //
    ////////////

    /// @notice Emitted once per scheduled price update at scheduling time.
    /// @dev    Indexers can derive activation by waiting for `effectiveAt`.
    event PriceUpdated(
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 effectiveAt
    );

    ////////////
    // Errors //
    ////////////

    error ZeroAddress();
    error VaultMismatch();
    error AssetMismatch();
    error DecimalsMismatch();
    error NoPriceData();
    error InvalidVestingDuration();
    error DrawdownVestingNotAllowed();
    error Overflow();
    error FutureScheduleTimestamp();

    //////////////
    // View Fns //
    //////////////

    /// @notice Get vault address priced by this oracle
    function vault() external view returns (address);

    /// @notice Returns the current pending update, if any.
    function pendingUpdate() external view returns (RecordedUpdate memory update, bool exists);

    /// @notice Returns the most recently activated (promoted-to-history) update.
    function lastEffectiveUpdate() external view returns (RecordedUpdate memory);

    ///////////////
    // Write Fns //
    ///////////////

    /// @notice Schedule a new share price; takes effect at `scheduleTimestamp + DELAY`.
    /// @param vault              The target vault (sanity-checked equal to `vault()`).
    /// @param newPrice           The new share price.
    /// @param scheduleTimestamp  The schedule origin. Main passes `block.timestamp`;
    ///                           remote (PR #2) passes main's send-timestamp from the
    ///                           CCIP message. Must satisfy `scheduleTimestamp <= block.timestamp`.
    /// @return recorded          The pending slot's resolved state.
    function setPriceInstantly(
        address vault,
        uint256 newPrice,
        uint256 scheduleTimestamp
    ) external returns (RecordedUpdate memory recorded);

    /// @notice Schedule a linear-vested share price change. Vesting begins at
    ///         `scheduleTimestamp + DELAY` and runs for `vestingDuration` seconds.
    ///         `startPrice` is computed automatically as the value the oracle WILL
    ///         report at the new `effectiveAt` based on effective-history only
    ///         (so a vesting scheduled while an earlier curve is in progress
    ///         continues smoothly from where that curve will be at activation).
    function scheduleLinearPriceUpdate(
        address vault,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 scheduleTimestamp
    ) external returns (RecordedUpdate memory recorded);
}
