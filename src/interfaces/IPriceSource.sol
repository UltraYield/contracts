// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IPriceSource {

    /**
     * @notice Get one-sided price quote
     * @param inAmount Amount of base token to convert
     * @param base Token being priced
     * @param quote Token used as unit of account
     * @return outAmount Amount of quote token equivalent to inAmount of base
     * @dev Assumes no price spread
     */
    function getQuote(
        uint256 inAmount,
        address base,
        address quote
    ) external view returns (uint256 outAmount);

    /**
     * @notice Get two-sided price quotes
     * @param inAmount Amount of base token to convert
     * @param base Token being priced
     * @param quote Token used as unit of account
     * @return bidOutAmount Amount of quote token for selling inAmount of base
     * @return askOutAmount Amount of quote token for buying inAmount of base
     */
    function getQuotes(
        uint256 inAmount,
        address base,
        address quote
    ) external view returns (uint256 bidOutAmount, uint256 askOutAmount);
}
