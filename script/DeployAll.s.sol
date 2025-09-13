// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IRSHook} from "../src/hooks/IRSHook.sol";
import {EthBaseIndex} from "../src/oracles/EthBaseIndex.sol";
import {IRSPoolFactory} from "../src/factory/IRSPoolFactory.sol";
import {IRSLiquidityCaps} from "../src/risk/IRSLiquidityCaps.sol";
import {IRSV4Router} from "../src/periphery/IRSV4Router.sol";
import {IWETH9} from "../src/interfaces/IWETH.sol";

import {IETHBaseIndex} from "../src/interfaces/IETHBaseIndex.sol";
import {IRiskEngine} from "../src/interfaces/IRiskEngine.sol";
import {RiskEngine} from "../src/risk/RiskEngine.sol";

contract DeployAll is Script {
    using Strings for uint256;
    using PoolIdLibrary for PoolKey;

    // ---------- helpers ----------
    function _envAddress(string memory key) internal returns (address a) {
        try vm.envAddress(key) returns (address v) {
            require(v != address(0), string.concat("Zero env: ", key));
            a = v;
        } catch {
            revert(string.concat("Missing env: ", key));
        }
    }

    function _envAddressOrZero(string memory key) internal returns (address a) {
        try vm.envAddress(key) returns (address v) {
            a = v;
        } catch {
            a = address(0);
        }
    }

    function _resolvePoolManager() internal returns (address pm) {
        pm = _envAddressOrZero("POOL_MANAGER");
        if (pm != address(0)) return pm;

        string memory cidKey = string.concat(
            "POOL_MANAGER_",
            block.chainid.toString()
        );
        pm = _envAddressOrZero(cidKey);
        if (pm != address(0)) return pm;

        if (block.chainid == 1) pm = _envAddressOrZero("POOL_MANAGER_MAINNET");
        else if (block.chainid == 11155111)
            pm = _envAddressOrZero("POOL_MANAGER_SEPOLIA");
        else if (block.chainid == 8453)
            pm = _envAddressOrZero("POOL_MANAGER_BASE");
        else if (block.chainid == 84532)
            pm = _envAddressOrZero("POOL_MANAGER_BASE_SEPOLIA");
        else if (block.chainid == 42161)
            pm = _envAddressOrZero("POOL_MANAGER_ARBITRUM");
        else if (block.chainid == 421614)
            pm = _envAddressOrZero("POOL_MANAGER_ARBITRUM_SEPOLIA");
        else if (block.chainid == 10)
            pm = _envAddressOrZero("POOL_MANAGER_OPTIMISM");
        else if (block.chainid == 137)
            pm = _envAddressOrZero("POOL_MANAGER_POLYGON");

        require(
            pm != address(0),
            string.concat(
                "PoolManager not set. Provide POOL_MANAGER or ",
                cidKey,
                " (or a network alias env var). chainId=",
                block.chainid.toString()
            )
        );
    }

    function _sort(
        address a,
        address b
    ) internal pure returns (address c0, address c1, bool flipped) {
        require(a != address(0) && b != address(0), "ZERO_TOKEN");
        require(a != b, "TOKENS_EQUAL");
        if (a < b) return (a, b, false);
        return (b, a, true);
    }

    function _invertSqrtPriceX96(uint160 sp) internal pure returns (uint160) {
        require(sp != 0, "BAD_SQRT_PRICE");
        uint256 Q96 = 2 ** 96;
        return uint160((Q96 * Q96) / sp);
    }

    // ---------- CREATE2 mining helpers ----------
    function _initCodeHash(
        address manager,
        address baseIndex,
        address riskEngine,
        address factory
    ) internal pure returns (bytes32) {
        // IRSHook constructor: (IPoolManager, IEthBaseIndex, IRiskEngine, address factory)
        bytes memory init = abi.encodePacked(
            type(IRSHook).creationCode,
            abi.encode(manager, baseIndex, riskEngine, factory)
        );
        return keccak256(init);
    }

    function _mine(
        bytes32 initCodeHash,
        address deployer
    ) internal pure returns (bytes32 salt, address predicted) {
        // Required flags advertised via low bits of the hook address
        uint160 FLAGS = Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;

        unchecked {
            for (uint256 i = 1; ; ++i) {
                bytes32 s = bytes32(i);
                bytes32 h = keccak256(
                    abi.encodePacked(bytes1(0xff), deployer, s, initCodeHash)
                );
                address a = address(uint160(uint256(h)));
                if ((uint160(a) & FLAGS) == FLAGS) return (s, a);
            }
        }
    }

    // ---------- deploy ----------
    function run() external {
        // ------- env -------
        address pmAddr = _resolvePoolManager();
        address wethAddr = _envAddress("WETH");
        address token0Env = _envAddress("TOKEN0");
        address token1Env = _envAddress("TOKEN1");
        address uiWallet = _envAddress("UI_WALLET");

        uint64 maturity = uint64(vm.envUint("MATURITY")); // seconds since epoch
        uint24 fee = uint24(vm.envUint("FEE")); // e.g. 3000
        int24 tickSpacing = int24(uint24(vm.envUint("TICK_SPACING"))); // e.g. 60
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96")); // e.g. 2**96 for 1.0

        require(maturity > block.timestamp, "BAD_MATURITY");
        require(sqrtPriceX96 != 0, "BAD_SQRT_PRICE");

        // sort for v4 key (and optionally invert price if you provided non-1 price)
        (address c0Addr, address c1Addr, bool flipped) = _sort(
            token0Env,
            token1Env
        );
        // if (flipped) { sqrtPriceX96 = _invertSqrtPriceX96(sqrtPriceX96); }

        vm.startBroadcast();

        IPoolManager manager = IPoolManager(pmAddr);

        // Core IRS stack (permissionless risk)
        EthBaseIndex base = new EthBaseIndex(
            msg.sender, // admin
            200_000, // alphaPPM (0.2 EMA)
            200_000, // maxDeviationPPM (±20%)
            1 hours, // maxStale
            new address[](0) // initialSources (empty for demo)
        );
        RiskEngine risk = new RiskEngine(msg.sender);
        IRSPoolFactory factory = new IRSPoolFactory(manager);

        // Periphery for demo/UI
        IRSLiquidityCaps caps = new IRSLiquidityCaps(msg.sender);
        IRSV4Router router = new IRSV4Router(
            manager,
            IWETH9(wethAddr),
            caps,
            msg.sender
        );

        vm.stopBroadcast();

        // ---------- mine salt off-chain (inside this script execution) ----------
        bytes32 initHash = _initCodeHash(
            address(manager),
            address(base),
            address(risk),
            address(factory)
        );
        (bytes32 salt, address predictedHook) = _mine(
            initHash,
            address(factory)
        );
        console2.log("Mined salt:        ", vm.toString(salt));
        console2.log("Predicted hook:    ", predictedHook);

        // ---------- create pool with mined salt ----------
        vm.startBroadcast();

        (PoolId id, address hook) = factory.createPool(
            Currency.wrap(c0Addr),
            Currency.wrap(c1Addr),
            fee,
            tickSpacing,
            sqrtPriceX96,
            maturity,
            IETHBaseIndex(address(base)),
            IRiskEngine(address(risk)),
            salt
        );

        // Optional: wire router if your factory/hook expects it
        // factory.setRouter(hook, address(router));

        // Demo caps for UI wallet
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0Addr),
            currency1: Currency.wrap(c1Addr),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        caps.setLP(uiWallet, true);
        caps.setCap(key.toId(), type(uint128).max);

        vm.stopBroadcast();

        // ------- logs for the UI -------
        console2.log("=== IRS v4 Deployment ===");
        console2.log("chainId");
        console2.log(block.chainid);
        console2.log("PoolManager");
        console2.log(pmAddr);
        console2.log("WETH");
        console2.log(wethAddr);

        console2.log("Env TOKEN0");
        console2.log(token0Env);
        console2.log("Env TOKEN1");
        console2.log(token1Env);
        console2.log("Pool currency0");
        console2.log(c0Addr);
        console2.log("Pool currency1");
        console2.log(c1Addr);
        console2.log("flipped (env->pool)");
        console2.log(flipped);

        console2.log("Index");
        console2.log(address(base));
        console2.log("RiskEngine");
        console2.log(address(risk));
        console2.log("IRSPoolFactory");
        console2.log(address(factory));
        console2.log("IRSLiquidityCaps");
        console2.log(address(caps));
        console2.log("IRSV4Router");
        console2.log(address(router));
        console2.log("Hook (Pool)");
        console2.log(hook);
        console2.log("Predicted hook");
        console2.log(predictedHook);

        console2.log("PoolId (bytes32)");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("PoolId (uint)");
        console2.log(uint256(PoolId.unwrap(id)));
    }
}
