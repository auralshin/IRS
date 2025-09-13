// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRiskEngine {
    function onFundingAccrued(address trader, int256 amount) external;
    function onPositionDelta(
        address trader,
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint256 kappa,
        uint256 maturity,
        int256 liquidityDelta
    ) external;
    function requireIM(address trader, uint256 nowTs) external view;
    function previewHealth(address trader, uint256 nowTs)
        external
        view
        returns (uint256 hf, int256 eq, uint256 im, uint256 mm, uint256 fundingDebt);
    // Optionally: previewAfterSwap, previewAfterAdd, previewAfterRemove
}
