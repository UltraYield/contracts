// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { InitializableOwnable } from "src/utils/InitializableOwnable.sol";
import { IUltraVaultOracle } from "src/interfaces/IUltraVaultOracle.sol";

/**
 * @title OracleAdmin
 * @notice Owner contract for managing UltraVaultOracle prices
 * @dev Allows owner and admin to update oracle prices
 */
contract OracleAdmin is InitializableOwnable {
    /// @notice Oracle contract to manage
    IUltraVaultOracle public oracle;

    /// @notice Address authorized to update prices
    address public admin;

    /// @notice Emitted when admin is updated
    event AdminUpdated(address oldAdmin, address newAdmin);

    /// @notice Error when caller is not admin or owner
    error NotAdminOrOwner();

    /**
     * @notice Initialize owner and oracle
     * @param _oracle Oracle contract address
     * @param _owner Owner address
     */
    constructor(address _oracle, address _owner) {
        initOwner(_owner);
        oracle = IUltraVaultOracle(_oracle);
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
    ) external onlyAdminOrOwner {
        oracle.setPrice(base, quote, price);
    }

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
    ) external onlyAdminOrOwner {
        oracle.setPrices(bases, quotes, prices);
    }

    /**
     * @notice Set base/quote pair price with gradual change
     * @param base The base asset
     * @param quote The quote asset
     * @param targetPrice The target price of the base in terms of the quote
     * @param vestingTime The time over which vesting would occur
     */
    function scheduleLinearPriceUpdate(
        address base,
        address quote,
        uint256 targetPrice,
        uint256 vestingTime
    ) external onlyAdminOrOwner {
        oracle.scheduleLinearPriceUpdate(
            base,
            quote,
            targetPrice,
            vestingTime
        );
    }

    /**
     * @notice Set multiple base/quote pair prices with gradual changes
     * @param bases The base assets
     * @param quotes The quote assets
     * @param prices The prices of the bases in terms of the quotes
     * @param vestingTimes Vesting times over which the updates occur
     * @dev Array lengths must match
     */
    function scheduleLinearPricesUpdates(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory prices,
        uint256[] memory vestingTimes
    ) external onlyAdminOrOwner {
        oracle.scheduleLinearPricesUpdates(
            bases,
            quotes,
            prices,
            vestingTimes
        );
    }

    /*//////////////////////////////////////////////////////////////
                            MANAGEMENT LOGIC
    //////////////////////////////////////////////////////////////*/

    function setAdmin(address _admin) external onlyOwner {
        if (admin != _admin) {
            emit AdminUpdated(admin, _admin);
            admin = _admin;
        }
    }

    function claimOracleOwnership() external onlyOwner {
        InitializableOwnable(address(oracle)).claimOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdminOrOwner() {
        if (msg.sender != owner && msg.sender != admin)
            revert NotAdminOrOwner();
        _;
    }
}
