// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IEthBaseIndex} from "../interfaces/IEthBaseIndex.sol";
import {IMarginManager} from "../interfaces/IMarginManager.sol";

contract IRSHook is IHooks {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable MANAGER;
    IEthBaseIndex public immutable BASE_INDEX;
    IMarginManager public immutable MARGIN;
    address public immutable FACTORY;

    struct PoolMeta {
        uint64 maturity;
        uint64 lastTs;
        uint256 lastCumIdx;
    }
    mapping(PoolId => PoolMeta) public poolMeta;

    constructor(
        IPoolManager _manager,
        IEthBaseIndex _base,
        IMarginManager _margin,
        address _factory
    ) {
        MANAGER = _manager;
        BASE_INDEX = _base;
        MARGIN = _margin;
        FACTORY = _factory;
    }

    function getHookPermissions()
        external
        pure
        returns (Hooks.Permissions memory p)
    {
        p.afterInitialize = true;
        p.beforeSwap = true;
        return p;
    }

    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        require(msg.sender == FACTORY, "NotFactory");
    }

    function setMaturity(PoolId id, uint64 maturityTs) external onlyFactory {
        (uint256 cum, uint64 ts) = BASE_INDEX.cumulativeIndex();
        poolMeta[id].maturity = maturityTs;
        poolMeta[id].lastCumIdx = cum;
        poolMeta[id].lastTs = ts;
    }

    function beforeInitialize(
        address /*sender*/,
        PoolKey calldata /*key*/,
        uint160 /*sqrtPriceX96*/
    ) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(
        address /*sender*/,
        PoolKey calldata /*key*/,
        uint160 /*sqrtPriceX96*/,
        int24 /*tick*/
    ) external view override returns (bytes4) {
        require(msg.sender == address(MANAGER), "NotManager");
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address /*sender*/,
        PoolKey calldata /*key*/,
        ModifyLiquidityParams calldata /*params*/,
        bytes calldata /*hookData*/
    ) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address /*sender*/,
        PoolKey calldata /*key*/,
        ModifyLiquidityParams calldata /*params*/,
        BalanceDelta /*delta*/,
        BalanceDelta /*feesAccrued*/,
        bytes calldata /*hookData*/
    ) external pure override returns (bytes4, BalanceDelta) {
        return (
            IHooks.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    function beforeRemoveLiquidity(
        address /*sender*/,
        PoolKey calldata /*key*/,
        ModifyLiquidityParams calldata /*params*/,
        bytes calldata /*hookData*/
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address /*sender*/,
        PoolKey calldata /*key*/,
        ModifyLiquidityParams calldata /*params*/,
        BalanceDelta /*delta*/,
        BalanceDelta /*feesAccrued*/,
        bytes calldata /*hookData*/
    ) external pure override returns (bytes4, BalanceDelta) {
        return (
            IHooks.afterRemoveLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    function beforeSwap(
        address /*sender*/,
        PoolKey calldata key,
        SwapParams calldata /*params*/,
        bytes calldata /*hookData*/
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(MANAGER), "NotManager");
        require(MARGIN.isHealthy(tx.origin), "MarginNotHealthy");

        // checkpoint ETH base index
        PoolId id = key.toId();
        (uint256 cum, uint64 ts) = BASE_INDEX.cumulativeIndex();
        PoolMeta storage m = poolMeta[id];
        m.lastCumIdx = cum;
        m.lastTs = ts;

        // ZERO_DELTA (no token adjustments) and no LP fee override (0)
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function afterSwap(
        address /*sender*/,
        PoolKey calldata /*key*/,
        SwapParams calldata /*params*/,
        BalanceDelta /*delta*/,
        bytes calldata /*hookData*/
    ) external pure override returns (bytes4, int128) {
        // Return zero unspecified delta
        return (IHooks.afterSwap.selector, int128(0));
    }

    function beforeDonate(
        address /*sender*/,
        PoolKey calldata /*key*/,
        uint256 /*amount0*/,
        uint256 /*amount1*/,
        bytes calldata /*hookData*/
    ) external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(
        address /*sender*/,
        PoolKey calldata /*key*/,
        uint256 /*amount0*/,
        uint256 /*amount1*/,
        bytes calldata /*hookData*/
    ) external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
