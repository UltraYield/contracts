// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { AggregatorV3Interface } from "src/interfaces/AggregatorV3Interface.sol";

/// @title ChainlinkRateProvider
/// @notice Converts between the vault's underlying asset and a secondary asset using Chainlink USD feeds.
contract ChainlinkRateProvider is IRateProvider {
    ///////////////
    // Constants //
    ///////////////

    uint8 internal constant MIN_DECIMALS = 6;
    uint8 internal constant MAX_DECIMALS = 18;

    ////////////
    // Errors //
    ////////////

    error ZeroAddress();
    error ZeroMaxStaleness();
    error InvalidDecimals();
    error FeedDecimalsMismatch();
    error UnsupportedAsset();
    error InvalidFeedAnswer();
    error StaleFeed();
    error IncompleteRound();

    ///////////////
    // Immutables //
    ///////////////

    address public immutable underlyingAsset;
    address public immutable secondaryAsset;
    AggregatorV3Interface public immutable underlyingFeed;
    AggregatorV3Interface public immutable secondaryFeed;
    uint8 public immutable secondaryDecimals;
    uint8 public immutable underlyingDecimals;
    uint256 public immutable maxStaleness;

    constructor(
        address _underlyingAsset,
        address _secondaryAsset,
        address _underlyingFeed,
        address _secondaryFeed,
        uint256 _maxStaleness
    ) {
        require(_underlyingAsset != address(0), ZeroAddress());
        require(_secondaryAsset != address(0), ZeroAddress());
        require(_underlyingFeed != address(0), ZeroAddress());
        require(_secondaryFeed != address(0), ZeroAddress());
        require(_maxStaleness != 0, ZeroMaxStaleness());

        underlyingAsset = _underlyingAsset;
        secondaryAsset = _secondaryAsset;
        underlyingFeed = AggregatorV3Interface(_underlyingFeed);
        secondaryFeed = AggregatorV3Interface(_secondaryFeed);

        uint8 _underlyingDecimals = IERC20Metadata(_underlyingAsset).decimals();
        uint8 _secondaryDecimals = IERC20Metadata(_secondaryAsset).decimals();
        uint8 _underlyingFeedDecimals = underlyingFeed.decimals();
        uint8 _secondaryFeedDecimals = secondaryFeed.decimals();

        _validateDecimals(_underlyingDecimals);
        _validateDecimals(_secondaryDecimals);
        _validateDecimals(_underlyingFeedDecimals);
        _validateDecimals(_secondaryFeedDecimals);
        require(_underlyingFeedDecimals == _secondaryFeedDecimals, FeedDecimalsMismatch());

        underlyingDecimals = _underlyingDecimals;
        secondaryDecimals = _secondaryDecimals;
        maxStaleness = _maxStaleness;
    }

    ////////////////
    // Public Fns //
    ////////////////

    /// @inheritdoc IRateProvider
    function convertToUnderlying(
        address _asset,
        uint256 assets
    ) external view returns (uint256) {
        require(_asset == secondaryAsset, UnsupportedAsset());
        uint256 assetPrice = _readPrice(secondaryFeed);
        uint256 underlyingPrice = _readPrice(underlyingFeed);
        uint256 result = Math.mulDiv(assets, assetPrice, underlyingPrice);
        return _normalizeDecimals(result, secondaryDecimals, underlyingDecimals);
    }

    /// @inheritdoc IRateProvider
    function convertFromUnderlying(
        address _asset,
        uint256 baseAssets
    ) external view returns (uint256) {
        require(_asset == secondaryAsset, UnsupportedAsset());
        uint256 assetPrice = _readPrice(secondaryFeed);
        uint256 underlyingPrice = _readPrice(underlyingFeed);
        uint256 result = Math.mulDiv(baseAssets, underlyingPrice, assetPrice);
        return _normalizeDecimals(result, underlyingDecimals, secondaryDecimals);
    }

    //////////////////
    // Internal Fns //
    //////////////////

    function _readPrice(AggregatorV3Interface feed) internal view returns (uint256) {
        (
            uint80 roundId,
            int256 answer,
            /* uint256 startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();
        _validateFeedAnswer(roundId, answer, updatedAt, answeredInRound);
        return uint256(answer);
    }

    function _validateFeedAnswer(
        uint80 roundId,
        int256 answer,
        uint256 updatedAt,
        uint80 answeredInRound
    ) internal view {
        require(answer > 0, InvalidFeedAnswer());
        require(updatedAt != 0, InvalidFeedAnswer());
        require(updatedAt <= block.timestamp, InvalidFeedAnswer());
        require(block.timestamp - updatedAt <= maxStaleness, StaleFeed());
        require(answeredInRound >= roundId, IncompleteRound());
    }

    function _normalizeDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            uint8 diff;
            unchecked {
                diff = toDecimals - fromDecimals;
            }
            return amount * _pow10(diff);
        } else {
            uint8 diff;
            unchecked {
                diff = fromDecimals - toDecimals;
            }
            return amount / _pow10(diff);
        }
    }

    function _pow10(uint256 exponent) internal pure returns (uint256) {
        return 10 ** exponent;
    }

    function _validateDecimals(uint8 _decimals) internal pure {
        require(_decimals >= MIN_DECIMALS && _decimals <= MAX_DECIMALS, InvalidDecimals());
    }
}
