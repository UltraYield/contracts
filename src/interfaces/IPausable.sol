// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IPausable {
    function paused() external view returns (bool);

    function pause() external;

    function unpause() external;
}
