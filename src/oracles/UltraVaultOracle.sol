// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { IUltraVaultOracle } from "src/interfaces/IUltraVaultOracle.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title UltraVaultOracle
/// @notice Oracle for setting base/quote pair prices by permissioned entities
/// @dev Price safety and reliability handled by other contracts/infrastructure
contract UltraVaultOracle is Ownable2Step, IUltraVaultOracle {
    using Checkpoints for Checkpoints.Trace208;

    ///////////
    // Types //
    ///////////

    struct PriceUpdate {
        uint256 startPrice;
        uint256 targetPrice;
        uint256 vestingDuration;
        uint256 timestamp;
    }

    struct PriceUpdateSlot {
        uint88 startPrice;
        uint88 targetPrice;
        uint40 vestingDuration;
        uint40 timestamp;
    }

    ///////////////
    // Constants //
    ///////////////

    address public immutable vault;

    uint256 public constant MIN_VESTING_DURATION = 24 hours;
    uint256 public constant MAX_VESTING_DURATION = 7 days;
    uint8 internal constant PRICE_FEED_DECIMALS = 18;

    /////////////
    // Storage //
    /////////////

    PriceUpdateSlot internal _lastUpdate;
    Checkpoints.Trace208 internal _priceUpdatesHistoryIndex;
    PriceUpdateSlot[] internal _priceUpdatesHistory;

    /////////////////
    // Constructor //
    /////////////////

    constructor(address _owner, address _vault, uint256 _initialPrice) Ownable(_owner) {
        // Checks
        require(_vault != address(0), ZeroAddress());
        vault = _vault;

        address asset = IERC4626(vault).asset();
        require(asset != address(0), ZeroAddress());
        uint8 assetDecimals = IERC20Metadata(asset).decimals();
        uint8 vaultDecimals = IERC20Metadata(vault).decimals();
        require(assetDecimals == vaultDecimals, DecimalsMismatch());

        _setPrice(_initialPrice);
    }

    //////////////
    // View Fns //
    //////////////

    /// @notice Get current vault's share price
    /// @return Vault's share price in terms of the base asset
    function currentSharePrice() public view returns (uint256) {
        return _getCurrentSharePrice();
    }

    /// @notice Get vault's share price at a specific timestamp
    /// @param timestamp Target timestamp for historical lookup
    /// @return Vault's share price in terms of the base asset
    function historicalSharePrice(uint256 timestamp) external view returns (uint256) {
        PriceUpdate memory update = _getPriceUpdateAtTimestamp(timestamp);
        return _priceAtTimestamp(update, timestamp);
    }

    /////////////////////
    // Write Functions //
    /////////////////////

    /// @notice Set new share price instantly
    /// @param _vault The target vault
    /// @param newPrice The new price of the vault's share in terms of the base asset
    function setPriceInstantly(
        address _vault,
        uint256 newPrice
    ) external onlyOwner {
        require(_vault == vault, VaultMismatch());
        _setPrice(newPrice);
    }

    //////////////////////////
    // Vesting Price Update //
    //////////////////////////

    /// @notice Set new share price with vesting
    /// @param _vault The target vault
    /// @param targetPrice The target price of the vault's share in terms of the base asset
    /// @param vestingDuration The duration over which vesting would occur
    function scheduleLinearPriceUpdate(
        address _vault,
        uint256 targetPrice,
        uint256 vestingDuration
    ) external onlyOwner {
        require(_vault == vault, VaultMismatch());
        _scheduleLinearPriceUpdate(
            targetPrice,
            vestingDuration
        );
    }

    //////////////
    // Internal //
    //////////////

    function _setPrice(uint256 newPrice) internal {
        _recordPriceUpdate(newPrice, 0, 0);
        emit PriceUpdated(newPrice, 0, 0);
    }

    function _scheduleLinearPriceUpdate(
        uint256 targetPrice,
        uint256 vestingDuration
    ) internal {
        // Enforce minimum and maximum linear update durations for operator safety.
        require(vestingDuration >= MIN_VESTING_DURATION && vestingDuration <= MAX_VESTING_DURATION, InvalidVestingDuration());

        uint256 currentPrice = _getCurrentSharePrice();
        _recordPriceUpdate(currentPrice, targetPrice, vestingDuration);

        emit PriceUpdated(currentPrice, targetPrice, vestingDuration);
    }

    function _recordPriceUpdate(uint256 startPrice, uint256 targetPrice, uint256 vestingDuration) internal {
        require(startPrice != 0, ZeroVestingStartPrice());
        if (vestingDuration > 0) {
            require(targetPrice > startPrice, DrawdownVestingNotAllowed());
        }
        uint88 maxPrice = type(uint88).max;
        require(startPrice <= maxPrice, Overflow());
        require(targetPrice <= maxPrice, Overflow());
        uint40 maxTimestamp = type(uint40).max;
        require(vestingDuration <= maxTimestamp, Overflow());
        require(block.timestamp <= maxTimestamp, Overflow());
        PriceUpdateSlot memory newPriceUpdate = PriceUpdateSlot({
            startPrice: uint88(startPrice),
            targetPrice: uint88(targetPrice),
            vestingDuration: uint40(vestingDuration),
            timestamp: uint40(block.timestamp)
        });

        _lastUpdate = newPriceUpdate;
        uint256 index = _priceUpdatesHistory.length;
        _priceUpdatesHistory.push(newPriceUpdate);
        _priceUpdatesHistoryIndex.push(uint48(block.timestamp), uint208(index));
    }

    function _getCurrentSharePrice() internal view returns (uint256) {
        PriceUpdate memory update = _getLastPriceUpdate();
        return _priceAtTimestamp(update, block.timestamp);
    }

    function _getLastPriceUpdate() internal view returns (PriceUpdate memory) {
        PriceUpdateSlot memory slot = _lastUpdate;
        return PriceUpdate({
            startPrice: uint256(slot.startPrice),
            targetPrice: uint256(slot.targetPrice),
            vestingDuration: uint256(slot.vestingDuration),
            timestamp: uint256(slot.timestamp)
        });
    }

    function _getPriceUpdateAtTimestamp(uint256 timestamp) internal view returns (PriceUpdate memory) {
        uint208 indexPlusOne = _priceUpdatesHistoryIndex.upperLookupRecent(uint48(timestamp));
        require(indexPlusOne != 0, NoPriceData());
        PriceUpdateSlot memory slot = _priceUpdatesHistory[uint256(indexPlusOne) - 1];
        return PriceUpdate({
            startPrice: uint256(slot.startPrice),
            targetPrice: uint256(slot.targetPrice),
            vestingDuration: uint256(slot.vestingDuration),
            timestamp: uint256(slot.timestamp)
        });
    }

    function _priceAtTimestamp(PriceUpdate memory update, uint256 timestamp) internal pure returns (uint256) {
        if (update.vestingDuration == 0 || timestamp <= update.timestamp) {
            return update.startPrice;
        }
        if (timestamp >= update.timestamp + update.vestingDuration) {
            return update.targetPrice;
        }
        // target price is guaranteed to be greater than start price if vesting duration is non-zero
        uint256 diff = update.targetPrice - update.startPrice;
        uint256 timeElapsed = timestamp - update.timestamp;
        return update.startPrice + (diff * timeElapsed / update.vestingDuration);
    }
}
