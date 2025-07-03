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
     * @return result The rate in terms of base asset (18 decimals)
     */
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256 result);
}
