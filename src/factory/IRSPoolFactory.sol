// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IETHBaseIndex} from "../interfaces/IETHBaseIndex.sol";
import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {IRSHook} from "../hooks/IRSHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract IRSPoolFactory {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable MANAGER;
    address public immutable THIS_FACTORY = address(this);

    event PoolCreated(PoolId poolId, address hook, uint64 maturity);

    constructor(IPoolManager _manager) {
        MANAGER = _manager;
    }

    /// @notice Deploys the IRSHook deterministically via CREATE2 using `salt`,
    ///         initializes the v4 pool, and sets maturity.
    /// @dev    The low 14 bits of the hook address must encode the permissions.
    function createPool(
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        uint64 maturityTs,
        IETHBaseIndex baseIndex,
        IRiskEngine riskEngine,
        bytes32 salt
    ) external returns (PoolId id, address hookAddr) {
        require(salt != bytes32(0), "SaltRequired");
        hookAddr = address(new IRSHook{salt: salt}(MANAGER, baseIndex, riskEngine, address(this)));

        uint160 FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;

        require((uint160(hookAddr) & FLAGS) == FLAGS, "HookFlagsMismatch");

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        MANAGER.initialize(key, sqrtPriceX96);

        id = key.toId();
        IRSHook(hookAddr).setMaturity(id, maturityTs);

        emit PoolCreated(id, hookAddr, maturityTs);
    }

    function setRouter(address hookAddr, address router) external {
        IRSHook(hookAddr).setRouter(router);
    }
}
