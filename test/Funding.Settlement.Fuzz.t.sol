// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ManagerHarness} from "./mocks/ManagerHarness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IRSV4Router} from "../src/periphery/IRSV4Router.sol";
import {IRSLiquidityCaps} from "../src/risk/IRSLiquidityCaps.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWETH9} from "../src/interfaces/IWETH.sol";

// Strict hook mock that enforces OnlyRouter on clearFundingOwedToken1
contract MockIRSHookStrict {
    address public router;
    mapping(bytes32 => int256) public owed;

    error NotRouter();

    function setRouter(address r) external { router = r; }
    function setOwed(bytes32 k, int256 v) external { owed[k] = v; }

    function keyOf(address owner, PoolKey calldata key, int24 l, int24 u, bytes32 salt)
        public pure returns (bytes32)
    {
        return keccak256(abi.encode(owner, key.currency0, key.currency1, l, u, salt));
    }

    function clearFundingOwedToken1(
        address owner,
        PoolKey calldata key,
        int24 l,
        int24 u,
        bytes32 salt
    ) external returns (int256 amt) {
        if (msg.sender != router) revert NotRouter();
        bytes32 k = keyOf(owner, key, l, u, salt);
        amt = owed[k];
        owed[k] = 0;
    }
}

contract Funding_Settlement_Fuzz is Test {
    ManagerHarness manager;
    MockERC20 token0;
    MockERC20 token1;
    MockIRSHookStrict hook;
    IRSV4Router router;

    address owner = address(0xABCD);
    address recv  = address(0xAABB);

    PoolKey key;
    bytes32 salt = bytes32(uint256(0x1234));

    function setUp() public {
        manager = new ManagerHarness();
        token0  = new MockERC20("T0","T0");
        token1  = new MockERC20("T1","T1");
        hook    = new MockIRSHookStrict();

    IRSLiquidityCaps caps = new IRSLiquidityCaps(address(this));
    router = new IRSV4Router(IPoolManager(address(manager)), IWETH9(address(0)), caps, address(this));
        hook.setRouter(address(router));

        // Manager can pay positive funding
        token1.mint(address(manager), 1_000_000 ether);
        // Owner can pay negative funding
        token1.mint(owner, 1_000_000 ether);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(owner);
        IERC20(address(token1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _setOwed(int256 v) internal {
        bytes32 k = hook.keyOf(owner, key, -60, 60, salt);
        hook.setOwed(k, v);
    }

    function test_notRouterGuard() public {
        // Direct call should revert
        vm.expectRevert(MockIRSHookStrict.NotRouter.selector);
        hook.clearFundingOwedToken1(owner, key, -60, 60, salt);
    }

    function test_fuzz_settleFunding_positive(int64 raw) public {
    int64 r = raw % 1000;
    if (r < 0) r = -r;
    int256 v = int256(uint256(uint64(r))) * 1e18; // [0..999] ETH
        _setOwed(v);

        uint256 before = IERC20(address(token1)).balanceOf(recv);
        router.settleFundingToken1(key, -60, 60, salt, owner, recv);
        uint256 afterB = IERC20(address(token1)).balanceOf(recv);

        assertEq(afterB - before, uint256(v), "positive funding paid out");

        // owed reset to 0
        bytes32 k = hook.keyOf(owner, key, -60, 60, salt);
        assertEq(hook.owed(k), 0, "owed cleared");
    }

    function test_fuzz_settleFunding_negative(int64 raw) public {
    int64 r = raw % 1000;
    if (r < 0) r = -r;
    int256 v = -int256(uint256(uint64(r) + 1) * 1e18); // [-1..-1000] ETH
        _setOwed(v);

        uint256 mBefore = IERC20(address(token1)).balanceOf(address(manager));

        vm.startPrank(owner);
        router.settleFundingToken1(key, -60, 60, salt, owner, owner);
        vm.stopPrank();

        // Manager received |v|
        assertEq(IERC20(address(token1)).balanceOf(address(manager)) - mBefore, uint256(-v), "negative funding pulled");

        // owed reset to 0
        bytes32 k = hook.keyOf(owner, key, -60, 60, salt);
        assertEq(hook.owed(k), 0, "owed cleared");
    }
}
