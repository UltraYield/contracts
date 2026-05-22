// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import { BaseVaultPriceManager } from "src/crosschain/BaseVaultPriceManager.sol";
import { IUltraVaultOracle, RecordedUpdate } from "src/interfaces/IUltraVaultOracle.sol";
import { PriceSyncMessage, PriceSyncMessageLib } from "src/crosschain/PriceSyncMessage.sol";

/// @title VaultPriceManager
/// @notice Main-chain manager of vault price updates with safety limits and
///         cross-chain CCIP broadcast. Every successful update on main is
///         atomically broadcast to every active destination chain so destinations
///         remain in lockstep.
/// @dev Auto-pauses the vault on sudden moves (limit breach), then forwards the
///      update to the oracle with `scheduleTimestamp = block.timestamp`. After
///      the call returns, broadcasts the recorded slot to every active destination.
///      With zero destinations configured, behaves identically to a single-chain
///      manager (plus the new 1-hour activation delay enforced by the oracle).
contract VaultPriceManager is BaseVaultPriceManager {
    using SafeERC20 for IERC20;

    ////////////
    // Events //
    ////////////

    event DestinationAdded(uint64 indexed selector, address receiver, uint256 gasLimit);
    event DestinationRemoved(uint64 indexed selector);
    event DestinationConfigUpdated(uint64 indexed selector, address receiver, uint256 gasLimit);
    event DestinationActiveSet(uint64 indexed selector, bool active);
    event Broadcast(uint64 indexed selector, uint64 indexed nonce, bytes32 messageId);
    event LinkWithdrawn(address indexed to, uint256 amount);

    ////////////
    // Errors //
    ////////////

    error DestinationNotFound();
    error DestinationAlreadyExists();
    error InvalidGasLimit();

    ///////////
    // Types //
    ///////////

    struct Destination {
        address receiver;
        uint256 gasLimit;
        bool active;
        bool exists;
    }

    /////////////
    // Storage //
    /////////////

    IRouterClient public immutable ccipRouter;
    IERC20 public immutable linkToken;

    mapping(uint64 chainSelector => Destination) public destinations;
    uint64[] public destinationSelectors;

    uint64 public broadcastNonce;

    /////////////////
    // Constructor //
    /////////////////

    constructor(
        address _oracle,
        address _vault,
        address _owner,
        address _ccipRouter,
        address _linkToken
    ) BaseVaultPriceManager(_oracle, _vault, _owner) {
        require(_ccipRouter != address(0) && _linkToken != address(0), ZeroAddress());
        ccipRouter = IRouterClient(_ccipRouter);
        linkToken = IERC20(_linkToken);

        // Pre-approve max LINK to the router so every future ccipSend can pull
        // its fee in a single tx. Convention used by Chainlink CCIP sender examples.
        IERC20(_linkToken).approve(_ccipRouter, type(uint256).max);
    }

    //////////////////
    // Oracle Logic //
    //////////////////

    /// @notice Schedule an instant price update on the local oracle and broadcast
    ///         to every active destination.
    /// @dev    Pauses the vault if the new price breaches the configured limits.
    function instantPriceUpdate(address _vault, uint256 newPrice) external onlyAdminOrOwner {
        require(_vault == vault, InvalidVault());
        bool mainPaused = _applyPauseIfNeeded(newPrice);
        RecordedUpdate memory recorded =
            oracle.setPriceInstantly(_vault, newPrice, block.timestamp);
        _broadcastUpdate(recorded, mainPaused);
    }

    /// @notice Schedule a linear-vested price update on the local oracle and
    ///         broadcast to every active destination.
    /// @dev    Pauses the vault if `newPrice` (the vesting target) breaches limits.
    function linearPriceUpdate(
        address _vault,
        uint256 newPrice,
        uint256 duration
    ) external onlyAdminOrOwner {
        require(_vault == vault, InvalidVault());
        bool mainPaused = _applyPauseIfNeeded(newPrice);
        RecordedUpdate memory recorded =
            oracle.scheduleLinearPriceUpdate(_vault, newPrice, duration, block.timestamp);
        _broadcastUpdate(recorded, mainPaused);
    }

    ///////////////////////////
    // Destination Registry  //
    ///////////////////////////

    function addDestination(uint64 selector, address receiver, uint256 gasLimit) external onlyOwner {
        require(receiver != address(0), ZeroAddress());
        require(gasLimit != 0, InvalidGasLimit());
        require(!destinations[selector].exists, DestinationAlreadyExists());
        destinations[selector] = Destination({
            receiver: receiver,
            gasLimit: gasLimit,
            active: true,
            exists: true
        });
        destinationSelectors.push(selector);
        emit DestinationAdded(selector, receiver, gasLimit);
    }

    function removeDestination(uint64 selector) external onlyOwner {
        require(destinations[selector].exists, DestinationNotFound());
        delete destinations[selector];
        uint256 len = destinationSelectors.length;
        for (uint256 i; i < len; ++i) {
            if (destinationSelectors[i] == selector) {
                destinationSelectors[i] = destinationSelectors[len - 1];
                destinationSelectors.pop();
                break;
            }
        }
        emit DestinationRemoved(selector);
    }

    function updateDestinationConfig(uint64 selector, address receiver, uint256 gasLimit)
        external
        onlyOwner
    {
        require(destinations[selector].exists, DestinationNotFound());
        require(receiver != address(0), ZeroAddress());
        require(gasLimit != 0, InvalidGasLimit());
        destinations[selector].receiver = receiver;
        destinations[selector].gasLimit = gasLimit;
        emit DestinationConfigUpdated(selector, receiver, gasLimit);
    }

    /// @notice Flip a destination's active flag. Admins can disable quickly to
    ///         unblock broadcasts in an emergency.
    function setDestinationActive(uint64 selector, bool active_) external onlyAdminOrOwner {
        require(destinations[selector].exists, DestinationNotFound());
        destinations[selector].active = active_;
        emit DestinationActiveSet(selector, active_);
    }

    function destinationsCount() external view returns (uint256) {
        return destinationSelectors.length;
    }

    function withdrawLink(address to, uint256 amount) external onlyOwner {
        require(to != address(0), ZeroAddress());
        linkToken.safeTransfer(to, amount);
        emit LinkWithdrawn(to, amount);
    }

    //////////////
    // Internal //
    //////////////

    function _broadcastUpdate(RecordedUpdate memory recorded, bool mainPaused) internal {
        uint64 nonce = ++broadcastNonce;

        PriceSyncMessage memory psm = PriceSyncMessage({
            nonce: nonce,
            mainScheduleTimestamp: uint64(block.timestamp),
            startPrice: uint88(recorded.startPrice),
            targetPrice: uint88(recorded.targetPrice),
            vestingDuration: uint40(recorded.vestingDuration),
            mainPaused: mainPaused
        });
        bytes memory payload = PriceSyncMessageLib.encode(psm);

        uint256 len = destinationSelectors.length;
        for (uint256 i; i < len; ++i) {
            uint64 selector = destinationSelectors[i];
            Destination memory dest = destinations[selector];
            if (!dest.active) continue;

            Client.EVM2AnyMessage memory ccipMsg = Client.EVM2AnyMessage({
                receiver: abi.encode(dest.receiver),
                data: payload,
                tokenAmounts: new Client.EVMTokenAmount[](0),
                extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: dest.gasLimit })),
                feeToken: address(linkToken)
            });

            // No try/catch: per design, any send failure must revert the whole tx
            // so destinations stay in lockstep (all-or-nothing broadcast).
            bytes32 messageId = ccipRouter.ccipSend(selector, ccipMsg);
            emit Broadcast(selector, nonce, messageId);
        }
    }
}
