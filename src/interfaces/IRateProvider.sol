// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

/**
 * @title IRateProvider
 * @notice Interface for rate provider contracts
 */
interface IRateProvider {

    /**
     * @notice Get the rate between an asset and the base asset
     * @param asset The asset to get rate for
     * @return rate The rate in terms of base asset (with same decimals)
     */
    function getRate(
        address asset
    ) external view returns (uint256 rate);
}
