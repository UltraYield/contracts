// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IOwnable {
    function owner() external view returns (address);

    function newOwner() external view returns (address);

    function transferOwnership(address _newOwner) external;

    function claimOwnership() external;
}
