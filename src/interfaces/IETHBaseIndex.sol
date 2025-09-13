// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEthBaseIndex {
    /// @notice per-second floating rate in 1e18 (e.g., 0.03 / YEAR)
    function ratePerSecond() external view returns (uint256);
    function lastUpdate() external view returns (uint64);

    /// @notice update the per-second rate; implementation should emit event
    function setRatePerSecond(uint256 newRatePerSecond) external;

    /// @notice returns cumulative index for funding calculations
    /// simple integral approximation: cum += ratePerSecond * (now - last)
    function cumulativeIndex() external view returns (uint256 cum, uint64 tstamp);
}