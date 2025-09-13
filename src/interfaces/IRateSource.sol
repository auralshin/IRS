// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

interface IRateSource {
    /// @return r rate per second in 1e18 scale
    function ratePerSecond() external view returns (uint256 r);

    /// @return t last update timestamp of this source (0 means undefined)
    function updatedAt() external view returns (uint64 t);
}
