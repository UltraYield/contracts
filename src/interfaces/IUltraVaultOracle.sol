// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IPriceSource } from "./IPriceSource.sol";

/**
 * @notice Price data for base/quote pair
 * @param price Current price
 * @param targetPrice Target price for gradual changes
 * @param timestampForFullVesting Target timestamp for full vesting
 * @param lastUpdatedTimestamp Last timestamp price was updated
 */
struct Price {
    uint256 price;
    uint256 targetPrice;
    uint256 timestampForFullVesting;
    uint256 lastUpdatedTimestamp;
}

/**
 * @title IUltraVaultOracle
 * @notice Interface for push-based price oracle
 * @dev Extends IPriceSource with price setting capabilities
 */
interface IUltraVaultOracle is IPriceSource {
    /**
     * @notice Set base/quote pair price
     * @param base The base asset
     * @param quote The quote asset
     * @param price The price of the base in terms of the quote
     */
    function setPrice(
        address base,
        address quote,
        uint256 price
    ) external;

    /**
     * @notice Set multiple base/quote pair prices
     * @param bases The base assets
     * @param quotes The quote assets
     * @param prices The prices of the bases in terms of the quotes
     * @dev Array lengths must match
     */
    function setPrices(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory prices
    ) external;

    /**
     * @notice Get price data for base/quote pair
     * @param base The base asset
     * @param quote The quote asset
     * @return Price data for the pair
     */
    function prices(
        address base,
        address quote
    ) external view returns (Price memory);

    /**
     * @notice Set base/quote pair price with gradual change
     * @param base The base asset
     * @param quote The quote asset
     * @param targetPrice The target price of the base in terms of the quote
     * @param timestampForFullVesting The target timestamp for full vesting
     */
    function scheduleLinearPriceUpdate(
        address base,
        address quote,
        uint256 targetPrice,
        uint256 timestampForFullVesting
    ) external;

    /**
     * @notice Set multiple base/quote pair prices with gradual changes
     * @param bases The base assets
     * @param quotes The quote assets
     * @param targetPrices The target prices of the bases in terms of the quotes
     * @param timestampsForFullVesting Target timestamps for full vesting
     * @dev Array lengths must match
     */
    function scheduleLinearPricesUpdate(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory targetPrices,
        uint256[] memory timestampsForFullVesting
    ) external;

    /**
     * @notice Get current price for base/quote pair
     * @param base The base asset
     * @param quote The quote asset
     * @return Current price of base in terms of quote
     */
    function getCurrentPrice(
        address base,
        address quote
    ) external view returns (uint256);
}
