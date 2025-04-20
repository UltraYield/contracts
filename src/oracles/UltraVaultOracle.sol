// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IUltraVaultOracle, Price } from "src/interfaces/IUltraVaultOracle.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { InitializableOwnable } from "src/utils/InitializableOwnable.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";
import { IERC20Metadata } from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title UltraVaultOracle
 * @notice Oracle for setting base/quote pair prices by permissioned entities
 * @dev Price safety and reliability handled by other contracts/infrastructure
 */
contract UltraVaultOracle is IPriceSource, InitializableOwnable {
    string public constant name = "UltraVaultOracle";

    // Events
    event PriceUpdated(
        address base,
        address quote,
        uint256 price,
        uint256 targetPrice,
        uint256 timestampForFullVesting
    );

    // Errors
    error NoPriceData(address base, address quote);
    error Misconfigured();

    /// @dev Fetch price by [base][quote]
    mapping(address => mapping(address => Price)) public prices;

    uint256 constant DECIMAL_PRECISION = 1e18;

    constructor(address _owner) {
        initOwner(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                            SET PRICE LOGIC
    //////////////////////////////////////////////////////////////*/

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
    ) external onlyOwner {
        _setPrice(base, quote, price);
    }

    /**
     * @notice Set multiple base/quote pair prices
     * @param bases The base assets
     * @param quotes The quote assets
     * @param priceArray The prices of the bases in terms of the quotes
     * @dev Array lengths must match
     */
    function setPrices(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory priceArray
    ) external onlyOwner {
        _checkLength(bases.length, quotes.length);
        _checkLength(bases.length, priceArray.length);

        for (uint256 i = 0; i < bases.length; i++) {
            _setPrice(bases[i], quotes[i], priceArray[i]);
        }
    }

    function _setPrice(
        address base,
        address quote,
        uint256 price
    ) internal {
        prices[base][quote] = Price({
            price: price,
            targetPrice: price,
            timestampForFullVesting: 0,
            lastUpdatedTimestamp: block.timestamp
        });

        emit PriceUpdated(base, quote, price, price, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        VESTING PRICE UPDATE
    //////////////////////////////////////////////////////////////*/

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
    ) external onlyOwner {
        _scheduleLinearPriceUpdate(
            base,
            quote,
            targetPrice,
            timestampForFullVesting
        );
    }

    /**
     * @notice Set multiple base/quote pair prices with gradual changes
     * @param bases The base assets
     * @param quotes The quote assets
     * @param targetPrices The target prices of the bases in terms of the quotes
     * @param timestampsForFullVesting The price increases per block
     * @dev Array lengths must match
     */
    function scheduleLinearPricesUpdate(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory targetPrices,
        uint256[] memory timestampsForFullVesting
    ) external onlyOwner {
        _checkLength(bases.length, quotes.length);
        _checkLength(bases.length, targetPrices.length);
        _checkLength(bases.length, timestampsForFullVesting.length);

        for (uint256 i = 0; i < bases.length; i++) {
            _scheduleLinearPriceUpdate(
                bases[i],
                quotes[i],
                targetPrices[i],
                timestampsForFullVesting[i]
            );
        }
    }

    function _scheduleLinearPriceUpdate(
        address base,
        address quote,
        uint256 targetPrice,
        uint256 timestampForFullVesting
    ) internal {
        if (timestampForFullVesting == 0)
            revert Misconfigured();

        uint256 price = _getCurrentPrice(base, quote);

        if (price == 0) revert Misconfigured();

        prices[base][quote] = Price({
            price: price,
            targetPrice: targetPrice,
            timestampForFullVesting: timestampForFullVesting,
            lastUpdatedTimestamp: block.timestamp
        });

        emit PriceUpdated(
            base,
            quote,
            price,
            targetPrice,
            timestampForFullVesting
        );
    }

    /*//////////////////////////////////////////////////////////////
                            QUOTE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Get current price for base/quote pair
    function getCurrentPrice(
        address base,
        address quote
    ) public view returns (uint256) {
        return _getCurrentPrice(base, quote);
    }

    function _getCurrentPrice(
        address base,
        address quote
    ) internal view returns (uint256) {
        Price memory price = prices[base][quote];

        if (price.timestampForFullVesting == 0) {
            return price.price;
        }

        // The price if fully vested
        if (block.timestamp >= price.timestampForFullVesting) {
            return price.targetPrice;
        }

        bool increase;
        uint256 diff;

        if (price.price <= price.targetPrice) {
            increase = true;
            diff = price.targetPrice - price.price;
        } else {
            diff = price.price - price.targetPrice;
        }

        uint256 changePercentage =
            (price.timestampForFullVesting - block.timestamp) *
            DECIMAL_PRECISION /
            (price.timestampForFullVesting - price.lastUpdatedTimestamp);

        uint256 change = diff - diff * changePercentage / DECIMAL_PRECISION;
 
        return increase ? price.price + change : price.price - change;
    }

    /// @inheritdoc IPriceSource
    function getQuote(
        uint256 inAmount, 
        address base, 
        address quote
    ) external view returns (uint256) {
        return _getQuote(inAmount, base, quote);
    }

    function _getQuote(
        uint256 inAmount,
        address base,
        address quote
    ) internal view returns (uint256) {
        uint256 price = _getCurrentPrice(base, quote);

        if (price == 0) revert NoPriceData(base, quote);

        uint8 baseDecimals = _getDecimals(base);
        uint8 quoteDecimals = _getDecimals(quote);

        // 18 is price feed decimals
        return inAmount * price * (10 ** quoteDecimals) / (10 ** (baseDecimals + 18));
    }

    /*//////////////////////////////////////////////////////////////
                                UTILS
    //////////////////////////////////////////////////////////////*/

    /// @dev Check array lengths match
    function _checkLength(uint256 lengthA, uint256 lengthB) internal pure {
        if (lengthA != lengthB) 
            revert Misconfigured();
    }

    /**
     * @notice Get asset decimals
     * @param asset Token address
     * @return The decimals of the asset
     * @dev Returns decimals if found, otherwise 18 for future deployments
     */
    function _getDecimals(address asset) internal view returns (uint8) {
        (bool success, bytes memory data) = 
            address(asset).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }
}
