// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEthBaseIndex} from "../interfaces/IEthBaseIndex.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal ETH APR index (per-second). Extend with LST rebase smoothing later.
/// Cumulative index integrates the rate over time for funding settlement.
contract EthBaseIndex is IEthBaseIndex, Ownable {
    uint256 public override ratePerSecond; // 1e18
    uint64  public override lastUpdate;    // seconds
    uint256 public cumulative;             // 1e18 * seconds

    event RateUpdated(uint256 newRatePerSecond);
    event Checkpoint(uint256 cumulative, uint64 nowTs);

    constructor(address admin, uint256 initialRatePerSecond) Ownable(admin) {
        lastUpdate = uint64(block.timestamp);
        ratePerSecond = initialRatePerSecond;
    }

    function _checkpoint() internal {
        uint64 nowTs = uint64(block.timestamp);
        uint64 dt = nowTs - lastUpdate;
        if (dt > 0) {
            // cum += r * dt
            cumulative += ratePerSecond * uint256(dt);
            lastUpdate = nowTs;
            emit Checkpoint(cumulative, nowTs);
        }
    }

    function setRatePerSecond(uint256 newRatePerSecond) external override onlyOwner {
        _checkpoint();
        ratePerSecond = newRatePerSecond;
        emit RateUpdated(newRatePerSecond);
    }

    function cumulativeIndex() external view override returns (uint256, uint64) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 dt = nowTs - lastUpdate;
        uint256 cum = cumulative + ratePerSecond * uint256(dt);
        return (cum, nowTs);
    }
}