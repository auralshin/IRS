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

// NOTE: If your v4 core exposes Add/Remove structs differently, fix this line:
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IRSPoolFactory} from "../src/factory/IRSPoolFactory.sol";
import {IRSHook} from "../src/hooks/IRSHook.sol";
import {EthBaseIndex} from "../src/oracles/EthBaseIndex.sol";
import {IETHBaseIndex} from "../src/interfaces/IETHBaseIndex.sol";
import {IRiskEngine} from "../src/interfaces/IRiskEngine.sol";
import {RiskEngine} from "../src/risk/RiskEngine.sol";

contract IRSHookTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager manager;
    EthBaseIndex base;
    IRSPoolFactory factory;
    RiskEngine risk;

    address owner = address(0xa);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    // ---------- CREATE2 helpers ----------
    function _computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)
                        )
                    )
                )
            )
        );
    }

    // Find a salt that yields hook address with desired flag bits (as per Hooks.ALL_HOOK_MASK)
    function _findSalt(address deployer) internal view returns (bytes32) {
        bytes memory creation = type(IRSHook).creationCode;

        // IMPORTANT: args order must match IRSHook constructor in your repo
        // constructor(IPoolManager, IEthBaseIndex, IRiskEngine, address factory)
        bytes memory args = abi.encode(
            manager, IETHBaseIndex(address(base)), IRiskEngine(address(risk)), address(factory)
        );
        bytes memory creationWithArgs = abi.encodePacked(creation, args);

        uint160 want = (
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        uint160 mask = Hooks.ALL_HOOK_MASK;

        // Small bounded search is fine for tests
        for (uint256 s = 1; s < 50_000; ++s) {
            address a = _computeAddress(deployer, s, creationWithArgs);
            if ((uint160(a) & mask) == want && a.code.length == 0) {
                return bytes32(s);
            }
        }
        revert("could not find salt");
    }

    function setUp() public {
        manager = new PoolManager(owner);

        address[] memory sources = new address[](0);
        base = new EthBaseIndex(
            address(this), // admin
            200_000, // alphaPPM
            200_000, // maxDeviationPPM
            3600, // maxStale (1h)
            sources
        );

        risk = new RiskEngine(owner);
        vm.prank(owner);
        risk.setOperator(address(this), true);

        factory = new IRSPoolFactory(manager);
    }

    function _createPool() internal returns (PoolKey memory key, PoolId id, address hook) {
        Currency c0 = Currency.wrap(address(0xC001));
        Currency c1 = Currency.wrap(address(0xC002));

        bytes32 salt = _findSalt(address(factory));

        (id, hook) = factory.createPool(
            c0,
            c1,
            3000,
            60,
            79228162514264337593543950336, // sqrtPriceX96 = 1.0
            uint64(block.timestamp + 30 days),
            IETHBaseIndex(address(base)),
            IRiskEngine(address(risk)),
            salt
        );

        key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});

        // Set ROUTER in hook to a test address
        vm.prank(address(factory));
        IRSHook(hook).setRouter(address(this));
    }

    // ---------- Tests ----------
    function test_CreatePoolAndMaturitySet() public {
        (, PoolId id, address hookAddr) = _createPool();
        assertTrue(hookAddr != address(0), "hook deployed");

        (uint64 maturity,,,,,) = IRSHook(hookAddr).poolMeta(id);
        assertGt(maturity, 0, "maturity set via factory");
    }

    function test_HookAddressHasCorrectFlags() public {
        (,, address hookAddr) = _createPool();

        uint160 mask = Hooks.ALL_HOOK_MASK;
        uint160 want = (
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        uint160 flags = uint160(hookAddr) & mask;
        assertEq(flags, want, "hook LSBs match desired flags");
    }

    function test_RiskGate_AllowsHealthy() public {
    (PoolKey memory key,, address hookAddr) = _createPool();

    // Simulate PoolManager calling beforeSwap; ROUTER is sender, alice is trader
    vm.startPrank(address(manager), address(this));
    SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 0});
    (bytes4 sel, BeforeSwapDelta d, uint24 optFee) = IRSHook(hookAddr).beforeSwap(address(this), key, sp, abi.encode(alice));
    vm.stopPrank();

    assertEq(sel, IHooks.beforeSwap.selector);
    assertEq(BeforeSwapDelta.unwrap(d), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
    assertEq(optFee, 0);
    }

    function test_RiskGate_BlocksUnhealthy() public {
    (PoolKey memory key,, address hookAddr) = _createPool();

    // Make bob under-margined by pushing positive funding liability (requires operator)
    risk.onFundingAccrued(bob, int256(1e18)); // owes 1 token1

    vm.startPrank(address(manager), address(this));
    SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 0});
    vm.expectRevert(bytes("margin: insufficient equity"));
    IRSHook(hookAddr).beforeSwap(address(this), key, sp, abi.encode(bob));
    vm.stopPrank();
    }

    function test_AfterInitialize_Selector() public {
        (PoolKey memory key,, address hookAddr) = _createPool();

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

    function test_MaturityBlocksAddLiquidity() public {
        (PoolKey memory key, PoolId id, address hookAddr) = _createPool();

        // Freeze: set a past maturity (factory-only)
        vm.prank(address(factory));
        IRSHook(hookAddr).setMaturity(id, uint64(block.timestamp - 1));

        vm.prank(address(manager)); // callbacks must be from manager
        ModifyLiquidityParams memory ap = ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1,
            salt: bytes32(0)
        });

        vm.expectRevert(bytes("PoolMatured"));
        IRSHook(hookAddr).beforeAddLiquidity(address(this), key, ap, abi.encode(alice));
    }
}
