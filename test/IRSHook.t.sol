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

import {IRSPoolFactory} from "../src/factory/IRSPoolFactory.sol";
import {IRSHook} from "../src/hooks/IRSHook.sol";
import {EthBaseIndex} from "../src/oracles/EthBaseIndex.sol";
import {MarginManager} from "../src/risk/MarginManager.sol";
import {IEthBaseIndex} from "../src/interfaces/IEthBaseIndex.sol";
import {IMarginManager} from "../src/interfaces/IMarginManager.sol";

contract IRSHookTest is Test {
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
            200_000, // alphaPPM (example value)
            200_000, // maxDeviationPPM (example value)
            3600, // maxStale (example value, 1 hour)
            sources // initialSources (empty for test)
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
            79228162514264337593543950336, // sqrtPriceX96 = 1.0
            uint64(block.timestamp + 30 days),
            IEthBaseIndex(address(base)),
            IMarginManager(address(margin))
        );

        key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});
    }

    function test_CreatePoolAndMaturitySet() public {
        (, PoolId id, address hookAddr) = _createPool();
        assertTrue(hookAddr != address(0), "hook deployed");

        (uint64 maturity,,,,,) = IRSHook(hookAddr).poolMeta(id);

        assertGt(maturity, 0, "maturity set via factory");
    }

    function test_HookAddressHasCorrectFlags() public {
        (,, address hookAddr) = _createPool();

        // Check lower bits of address for AFTER_INITIALIZE and BEFORE_SWAP
        uint160 flags = uint160(uint160(uint160(uint160(uint160(uint160(uint160(hookAddr)))))));
        // mask only the bottom 14 bits (as per Hooks.ALL_HOOK_MASK)
        uint160 mask = Hooks.ALL_HOOK_MASK;
        uint160 want = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        assertEq(flags & mask, want, "hook LSBs match desired flags");
    }

    function test_MarginGate_AllowsWhitelisted() public {
        (PoolKey memory key,, address hookAddr) = _createPool();

        // Simulate PoolManager calling beforeSwap; alice is tx.origin
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

        // bob not whitelisted → should revert in beforeSwap
        vm.startPrank(address(manager), bob);
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 0});

        vm.expectRevert(bytes("MarginNotHealthy"));
        IRSHook(hookAddr).beforeSwap(address(this), key, sp, "");
        vm.stopPrank();
    }

    function test_AfterInitialize_Selector() public {
        (PoolKey memory key,, address hookAddr) = _createPool();

        // afterInitialize checks msg.sender == manager; prank as manager
        vm.prank(address(manager));
        bytes4 sel =
            IRSHook(hookAddr).afterInitialize(address(this), key, 79228162514264337593543950336, 0);
        assertEq(sel, IHooks.afterInitialize.selector, "afterInitialize selector");
    }

    function test_SetMaturity_OnlyFactory() public {
        (, PoolId id, address hookAddr) = _createPool();
        vm.expectRevert(bytes("NotFactory"));
        IRSHook(hookAddr).setMaturity(id, uint64(block.timestamp + 10 days));
        vm.prank(address(factory));
        IRSHook(hookAddr).setMaturity(id, uint64(block.timestamp + 11 days));
    }
}
