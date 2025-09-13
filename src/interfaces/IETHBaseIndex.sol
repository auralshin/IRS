// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

/// @notice Interface for a simple per-second ETH APR index.
/// Provides both instantaneous rate (1e18 scale) and cumulative integral
/// for funding calculations in IRS hooks.
interface IETHBaseIndex {
    /// @notice current floating rate per second (1e18 scale)
    function ratePerSecond() external view returns (uint256);

    /// @notice timestamp used for last cumulative checkpoint
    function lastUpdate() external view returns (uint64);

    /// @notice governance/manual override for the per-second rate (see notes below)
    function setRatePerSecond(uint256 newRatePerSecond) external;

    /// @notice cumulative integral of rate over time (1e18 * seconds)
    function cumulativeIndex() external view returns (uint256 cum, uint64 tstamp);
}
