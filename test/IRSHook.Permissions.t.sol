// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// NOTE: If your v4 core exposes Add/Remove structs differently, fix these two lines:
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IRSPoolFactory} from "../src/factory/IRSPoolFactory.sol";
import {IRSHook} from "../src/hooks/IRSHook.sol";
import {EthBaseIndex} from "../src/oracles/EthBaseIndex.sol";
import {MarginManager} from "../src/risk/MarginManager.sol";
import {IEthBaseIndex} from "../src/interfaces/IEthBaseIndex.sol";
import {IMarginManager} from "../src/interfaces/IMarginManager.sol";

contract IRSHook_Permissions is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager manager;
    EthBaseIndex base;
    MarginManager margin;
    IRSPoolFactory factory;

    address owner = address(0xa);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        manager = new PoolManager(owner);

        address[] memory sources = new address[](0);
        base = new EthBaseIndex(
            address(this), // admin
            200_000, // alphaPPM
            200_000, // maxDeviationPPM
            3600, // maxStale
            sources
        );
        margin = new MarginManager(address(this));
        factory = new IRSPoolFactory(manager);

        margin.setWhitelisted(alice, true);
        margin.setWhitelisted(bob, false);
    }

    function _createPool() internal returns (PoolKey memory key, PoolId id, address hook) {
        Currency c0 = Currency.wrap(address(0xC001));
        Currency c1 = Currency.wrap(address(0xC002));

        (id, hook) = factory.createPool(
            c0,
            c1,
            3000,
            60,
            79228162514264337593543950336, // sqrtPriceX96=1
            uint64(block.timestamp + 30 days),
            IEthBaseIndex(address(base)),
            IMarginManager(address(margin))
        );

        key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});
    }

    function test_FlagsIncludeAddRemoveHooks() public {
        (,, address hookAddr) = _createPool();

        uint160 mask = Hooks.ALL_HOOK_MASK;
        uint160 want = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;

        uint160 flags = uint160(hookAddr) & mask;
        assertEq(flags, want, "hook LSB flags must include add/remove");
    }

    function test_MarginGate_UsesSender_WhitelistedOK() public {
        (PoolKey memory key,, address hookAddr) = _createPool();

        vm.startPrank(address(manager), alice);
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 0});

        (bytes4 sel, BeforeSwapDelta d, uint24 optFee) =
            IRSHook(hookAddr).beforeSwap(alice, key, sp, "");
        vm.stopPrank();

        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(
            BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA)
        );
        assertEq(optFee, 0);
    }

    function test_MarginGate_BlocksNonWhitelisted() public {
        (PoolKey memory key,, address hookAddr) = _createPool();

        vm.startPrank(address(manager), bob);
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 0});

        // IMPORTANT: sender param is used, not tx.origin
        vm.expectRevert(bytes("MarginNotHealthy"));
        IRSHook(hookAddr).beforeSwap(bob, key, sp, "");
        vm.stopPrank();
    }

    function test_AfterInitialize_Selector() public {
        (PoolKey memory key,, address hookAddr) = _createPool();

        vm.prank(address(manager));
        bytes4 sel =
            IRSHook(hookAddr).afterInitialize(address(this), key, 79228162514264337593543950336, 0);
        assertEq(sel, IHooks.afterInitialize.selector);
    }

    function test_SetMaturity_OnlyFactoryAndBlocksAdd() public {
        (PoolKey memory key, PoolId id, address hookAddr) = _createPool();

        // Only factory can set maturity
        vm.expectRevert(bytes("NotFactory"));
        IRSHook(hookAddr).setMaturity(id, uint64(block.timestamp + 5 days));

        vm.prank(address(factory));
        IRSHook(hookAddr).setMaturity(id, uint64(block.timestamp - 1)); // already matured

        // After maturity, beforeAddLiquidity must revert with PoolMatured
        vm.prank(address(manager)); // callbacks always from manager
        ModifyLiquidityParams memory ap = ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1,
            salt: bytes32(0)
        });

        vm.expectRevert(bytes("PoolMatured"));
        IRSHook(hookAddr).beforeAddLiquidity(alice, key, ap, "");
    }
}
