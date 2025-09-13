// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRiskEngine {
    struct PoolRiskParams {
        uint256 imBps;
        uint256 mmBps;
        uint256 durationFactor;
        uint256 maxSingleNotional;
        uint256 maxAccountNotional;
        bool enabled;
    }

    function onFundingAccrued(address trader, int256 deltaToken1) external;

    function onPositionDelta(
        address trader,
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint256 kappa,
        uint256 maturity,
        int256 LDelta
    ) external;

    function requireIM(address trader, uint256 nowTs) external view;
}
