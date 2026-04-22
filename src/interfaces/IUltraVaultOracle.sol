// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { IPriceSourceV1 } from "src/legacy/v1/interfaces/IPriceSourceV1.sol";

/// @title IUltraVaultOracle
/// @notice Interface for push-based price oracle
/// @dev Extends IPriceSource with price setting capabilities
/// @dev Also implements IPriceSourceV1 for backwards compatibility with V1 vaults
interface IUltraVaultOracle is IPriceSource, IPriceSourceV1 {
    ////////////
    // Events //
    ////////////

    event PriceUpdated(
        uint256 startPrice,
        uint256 targetPrice,
        uint256 vestingDuration
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
    error ZeroVestingStartPrice();
    error DrawdownVestingNotAllowed();
    error Overflow();

    //////////////
    // View Fns //
    //////////////

    /// @notice Get vault address priced by this oracle
    function vault() external view returns (address);

    ///////////////
    // Write Fns //
    ///////////////

    /// @notice Set new share price instantly
    /// @param vault The target vault
    /// @param newPrice The new price of the vault's share in terms of the base asset
    function setPriceInstantly(
        address vault,
        uint256 newPrice
    ) external;

    /// @notice Set new share price with vesting
    /// @param vault The target vault
    /// @param targetPrice The target price of the vault's share in terms of the base asset
    /// @param vestingDuration The duration over which vesting would occur
    function scheduleLinearPriceUpdate(
        address vault,
        uint256 targetPrice,
        uint256 vestingDuration
    ) external;
}
