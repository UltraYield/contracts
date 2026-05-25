// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { IUltraVaultOracle, RecordedUpdate } from "src/interfaces/IUltraVaultOracle.sol";
import { IPriceSourceV1 } from "src/legacy/v1/interfaces/IPriceSourceV1.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title UltraVaultOracle
/// @notice Oracle for setting base/quote pair prices by permissioned entities
/// @dev Price safety and reliability handled by other contracts/infrastructure.
/// @dev Every update is recorded with `effectiveAt = scheduleTimestamp + DELAY`
///      to support cross-chain price synchronization. A new update issued while
///      the previous one is still in its activation window replaces the previous
///      pending update; after activation, new updates queue (lazy promotion).
contract UltraVaultOracle is Ownable2Step, IUltraVaultOracle {
    using Checkpoints for Checkpoints.Trace208;

    ///////////
    // Types //
    ///////////

    struct PriceUpdateSlot {
        uint88 startPrice;
        uint88 targetPrice;
        uint40 vestingDuration;
        uint40 effectiveAt;
    }

    ///////////////
    // Constants //
    ///////////////

    address public immutable vault;
    address public immutable asset;

    /// @notice Activation delay applied to every scheduled update. Identical on
    ///         every chain so the same `(scheduleTimestamp, startPrice, targetPrice,
    ///         vestingDuration)` resolves to the same price at every wall-clock instant.
    uint256 public constant DELAY = 1 hours;
    uint256 public constant MIN_VESTING_DURATION = 24 hours;
    uint256 public constant MAX_VESTING_DURATION = 7 days;
    uint8 internal constant PRICE_FEED_DECIMALS = 18;

    /////////////
    // Storage //
    /////////////

    /// @dev The next update awaiting activation. May or may not be currently
    ///      effective — lazy promotion to `_effectiveHistory` happens on the
    ///      next write that observes `effectiveAt <= block.timestamp`.
    PriceUpdateSlot internal _pending;
    bool internal _pendingExists;

    /// @dev All updates that have already been promoted (no longer subject to
    ///      replace-pending). Indexed by `effectiveAt` for binary-search lookup.
    PriceUpdateSlot[] internal _effectiveHistory;
    Checkpoints.Trace208 internal _effectiveHistoryIndex;

    /////////////////
    // Constructor //
    /////////////////

    constructor(address _owner, address _vault, uint256 _initialPrice) Ownable(_owner) {
        require(_vault != address(0), ZeroAddress());
        vault = _vault;

        address _asset = IERC4626(vault).asset();
        require(_asset != address(0), ZeroAddress());
        asset = _asset;
        uint8 assetDecimals = IERC20Metadata(_asset).decimals();
        uint8 vaultDecimals = IERC20Metadata(vault).decimals();
        require(assetDecimals == vaultDecimals, DecimalsMismatch());

        _seedInitialPrice(_initialPrice);
    }

    //////////////
    // View Fns //
    //////////////

    /// @notice Get current vault's share price
    /// @return Vault's share price in terms of the base asset
    function currentSharePrice() public view returns (uint256) {
        return _priceAt(block.timestamp);
    }

    /// @notice Get vault's share price at a specific timestamp
    /// @param timestamp Target timestamp for historical lookup
    /// @return Vault's share price in terms of the base asset
    function historicalSharePrice(uint256 timestamp) external view returns (uint256) {
        return _priceAt(timestamp);
    }

    /// @inheritdoc IPriceSourceV1
    /// @dev Backwards-compatibility shim for V1 vaults, which call
    /// `oracle().getQuote(totalSupply(), share(), asset())`. Only the
    /// (vault, asset) pair is supported; any other combination reverts.
    /// @dev Vault and asset decimals are required to match in the constructor,
    /// so the V1 decimal-scaling formula collapses to `inAmount * price / 1e18`.
    function getQuote(
        uint256 inAmount,
        address base,
        address quote
    ) external view returns (uint256) {
        require(base == vault, VaultMismatch());
        require(quote == asset, AssetMismatch());
        return inAmount * _priceAt(block.timestamp) / 1e18;
    }

    /// @inheritdoc IUltraVaultOracle
    function pendingUpdate() external view returns (RecordedUpdate memory update, bool exists) {
        exists = _pendingExists;
        if (exists) {
            update = _toRecorded(_pending);
        }
    }

    /// @inheritdoc IUltraVaultOracle
    function lastEffectiveUpdate() external view returns (RecordedUpdate memory) {
        return _toRecorded(_effectiveHistory[_effectiveHistory.length - 1]);
    }

    /////////////////////
    // Write Functions //
    /////////////////////

    /// @inheritdoc IUltraVaultOracle
    function setPriceInstantly(
        address _vault,
        uint256 newPrice,
        uint256 scheduleTimestamp
    ) external onlyOwner returns (RecordedUpdate memory) {
        require(_vault == vault, VaultMismatch());
        return _writeInstant(newPrice, scheduleTimestamp);
    }

    /// @inheritdoc IUltraVaultOracle
    function scheduleLinearPriceUpdate(
        address _vault,
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 scheduleTimestamp
    ) external onlyOwner returns (RecordedUpdate memory) {
        require(_vault == vault, VaultMismatch());
        return _writeLinear(targetPrice, vestingDuration, scheduleTimestamp);
    }

    //////////////
    // Internal //
    //////////////

    function _seedInitialPrice(uint256 initialPrice) internal {
        require(initialPrice != 0 && initialPrice <= type(uint88).max, Overflow());
        require(block.timestamp <= type(uint40).max, Overflow());
        PriceUpdateSlot memory slot = PriceUpdateSlot({
            startPrice: uint88(initialPrice),
            targetPrice: uint88(initialPrice),
            vestingDuration: 0,
            effectiveAt: uint40(block.timestamp)
        });
        _effectiveHistory.push(slot);
        // Store a 1-based position so `0` is reserved as the "no checkpoint"
        // sentinel returned by `upperLookupRecent`. Retrieval subtracts 1.
        _effectiveHistoryIndex.push(uint48(block.timestamp), uint208(_effectiveHistory.length));
        emit PriceUpdated(initialPrice, initialPrice, 0, block.timestamp);
    }

    function _writeInstant(
        uint256 newPrice,
        uint256 scheduleTimestamp
    ) internal returns (RecordedUpdate memory) {
        require(scheduleTimestamp <= block.timestamp, FutureScheduleTimestamp());
        require(newPrice != 0 && newPrice <= type(uint88).max, Overflow());
        uint256 effectiveAt = scheduleTimestamp + DELAY;
        require(effectiveAt <= type(uint40).max, Overflow());

        _promotePendingIfEffective(block.timestamp);

        _pending = PriceUpdateSlot({
            startPrice: uint88(newPrice),
            targetPrice: uint88(newPrice),
            vestingDuration: 0,
            effectiveAt: uint40(effectiveAt)
        });
        _pendingExists = true;

        emit PriceUpdated(newPrice, newPrice, 0, effectiveAt);

        return RecordedUpdate({
            startPrice: newPrice,
            targetPrice: newPrice,
            vestingDuration: 0,
            effectiveAt: effectiveAt
        });
    }

    function _writeLinear(
        uint256 targetPrice,
        uint256 vestingDuration,
        uint256 scheduleTimestamp
    ) internal returns (RecordedUpdate memory) {
        require(scheduleTimestamp <= block.timestamp, FutureScheduleTimestamp());
        require(
            vestingDuration >= MIN_VESTING_DURATION && vestingDuration <= MAX_VESTING_DURATION,
            InvalidVestingDuration()
        );
        require(targetPrice != 0 && targetPrice <= type(uint88).max, Overflow());
        // vestingDuration is bounded by MAX_VESTING_DURATION (= 7 days) which fits in uint40.

        uint256 effectiveAt = scheduleTimestamp + DELAY;
        require(effectiveAt <= type(uint40).max, Overflow());

        _promotePendingIfEffective(block.timestamp);

        // The new pending (if any current pending hasn't activated) replaces the
        // current pending. So the startPrice of the new pending is the price the
        // oracle would report at the new `effectiveAt` assuming ONLY the effective
        // history applies (the replaced pending never materializes).
        uint256 startPrice = _priceFromEffectiveHistory(effectiveAt);
        require(targetPrice > startPrice, DrawdownVestingNotAllowed());

        _pending = PriceUpdateSlot({
            startPrice: uint88(startPrice),
            targetPrice: uint88(targetPrice),
            vestingDuration: uint40(vestingDuration),
            effectiveAt: uint40(effectiveAt)
        });
        _pendingExists = true;

        emit PriceUpdated(startPrice, targetPrice, vestingDuration, effectiveAt);

        return RecordedUpdate({
            startPrice: startPrice,
            targetPrice: targetPrice,
            vestingDuration: vestingDuration,
            effectiveAt: effectiveAt
        });
    }

    /// @dev If the pending slot is set and its `effectiveAt` has passed by `nowTs`,
    ///      promote it into the effective history (Checkpoints index by effectiveAt).
    function _promotePendingIfEffective(uint256 nowTs) internal {
        if (!_pendingExists) return;
        if (uint256(_pending.effectiveAt) > nowTs) return;
        _effectiveHistory.push(_pending);
        _effectiveHistoryIndex.push(uint48(_pending.effectiveAt), uint208(_effectiveHistory.length));
        _pendingExists = false;
    }

    function _priceAt(uint256 atTime) internal view returns (uint256) {
        if (_pendingExists && uint256(_pending.effectiveAt) <= atTime) {
            return _interpolate(_pending, atTime);
        }
        return _priceFromEffectiveHistory(atTime);
    }

    /// @dev Computes the price the oracle would report at `atTime` considering
    ///      ONLY the effective history (ignoring any current pending — which is
    ///      what we need when computing the startPrice for a NEW pending that
    ///      will replace the current one).
    function _priceFromEffectiveHistory(uint256 atTime) internal view returns (uint256) {
        uint208 indexPlusOne = _effectiveHistoryIndex.upperLookupRecent(uint48(atTime));
        require(indexPlusOne != 0, NoPriceData());
        PriceUpdateSlot memory slot = _effectiveHistory[uint256(indexPlusOne) - 1];
        return _interpolate(slot, atTime);
    }

    function _interpolate(PriceUpdateSlot memory slot, uint256 atTime) internal pure returns (uint256) {
        if (slot.vestingDuration == 0) {
            return uint256(slot.targetPrice);
        }
        if (atTime <= uint256(slot.effectiveAt)) {
            return uint256(slot.startPrice);
        }
        uint256 endsAt = uint256(slot.effectiveAt) + uint256(slot.vestingDuration);
        if (atTime >= endsAt) {
            return uint256(slot.targetPrice);
        }
        uint256 diff = uint256(slot.targetPrice) - uint256(slot.startPrice);
        uint256 elapsed = atTime - uint256(slot.effectiveAt);
        return uint256(slot.startPrice) + (diff * elapsed) / uint256(slot.vestingDuration);
    }

    function _toRecorded(PriceUpdateSlot memory slot) internal pure returns (RecordedUpdate memory) {
        return RecordedUpdate({
            startPrice: uint256(slot.startPrice),
            targetPrice: uint256(slot.targetPrice),
            vestingDuration: uint256(slot.vestingDuration),
            effectiveAt: uint256(slot.effectiveAt)
        });
    }
}
