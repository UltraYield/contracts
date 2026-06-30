// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ChainlinkRateProvider } from "src/oracles/ChainlinkRateProvider.sol";

/// @title StableChainlinkRateProvider
/// @notice ChainlinkRateProvider for stable (1:1) asset pairs. Reverts when the two
///         feed prices deviate from parity by more than a configurable tolerance.
contract StableChainlinkRateProvider is ChainlinkRateProvider, Ownable2Step {
    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MAX_DEVIATION_BPS = 300;

    /////////////
    // Storage //
    /////////////

    /// @notice Maximum allowed deviation from the 1:1 rate, in basis points.
    uint256 public maxDeviationBps;

    ////////////
    // Errors //
    ////////////

    error RateDeviationTooHigh();
    error InvalidMaxDeviationBps();

    ////////////
    // Events //
    ////////////

    event MaxDeviationBpsUpdated(uint256 oldValue, uint256 newValue);

    /////////////////
    // Constructor //
    /////////////////

    constructor(
        address _owner,
        address _underlyingAsset,
        address _secondaryAsset,
        address _underlyingFeed,
        address _secondaryFeed,
        uint256 _maxStaleness,
        uint256 _maxDeviationBps
    )
        ChainlinkRateProvider(_underlyingAsset, _secondaryAsset, _underlyingFeed, _secondaryFeed, _maxStaleness)
        Ownable(_owner)
    {
        _setMaxDeviationBps(_maxDeviationBps);
    }

    ////////////////
    // Public Fns //
    ////////////////

    /// @notice Update the maximum allowed deviation from the 1:1 rate.
    /// @param newMaxDeviationBps New tolerance in basis points, within (0, MAX_DEVIATION_BPS].
    function setMaxDeviationBps(uint256 newMaxDeviationBps) external onlyOwner {
        _setMaxDeviationBps(newMaxDeviationBps);
    }

    //////////////////
    // Internal Fns //
    //////////////////

    /// @dev Reverts when the two feed prices deviate from parity by more than `maxDeviationBps`.
    function _validateRate(uint256 underlyingPrice, uint256 assetPrice) internal view override {
        uint256 diff = assetPrice > underlyingPrice
            ? assetPrice - underlyingPrice
            : underlyingPrice - assetPrice;
        require(diff * BPS_DENOMINATOR <= underlyingPrice * maxDeviationBps, RateDeviationTooHigh());
    }

    function _setMaxDeviationBps(uint256 newMaxDeviationBps) internal {
        require(
            newMaxDeviationBps != 0 && newMaxDeviationBps <= MAX_DEVIATION_BPS,
            InvalidMaxDeviationBps()
        );
        uint256 oldValue = maxDeviationBps;
        maxDeviationBps = newMaxDeviationBps;
        emit MaxDeviationBpsUpdated(oldValue, newMaxDeviationBps);
    }
}
