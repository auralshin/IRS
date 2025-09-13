// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IIRSHook {
    function clearFundingOwedToken1(address owner, PoolKey calldata key, int24 lower, int24 upper, bytes32 salt) external returns (int256);
}
