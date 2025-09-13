// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IRiskEngine} from "../interfaces/IRiskEngine.sol";
import {IETHBaseIndex} from "../interfaces/IETHBaseIndex.sol";

/// @notice IRS v4 Hook with funding accrual, maturity gating, and position accounting.
/// @dev Per-pool "fundingGrowthGlobalX128" accrues from ETH Base Index deltas / totalLiquidity.
///      Positions snapshot fundingGrowth on add/remove; funding owed can be collected post-accrual.
contract IRSHook is IHooks {
    event FundingAccrued(PoolId indexed id, int256 growthX128Delta, uint32 dt);
    event FundingOwedCleared(
        address indexed owner, PoolId indexed id, int24 lower, int24 upper, int256 amount
    );

    address public ROUTER;

    // For router restriction, set ROUTER after deployment (or via factory)
    function setRouter(address r) external onlyFactory {
        ROUTER = r;
    }

    using PoolIdLibrary for PoolKey;

    // --- Immutables ---
    IPoolManager public immutable MANAGER;
    IETHBaseIndex public immutable BASE_INDEX;
    IRiskEngine public immutable RISK;
    // Removed MARGIN
    address public immutable FACTORY;

    // Fixed-point scale (like feeGrowth global): 2^128
    uint256 internal constant FP = 1 << 128;

    struct PoolMeta {
        uint64 maturity; // maturity timestamp
        uint64 lastTs; // last index checkpoint time
        uint256 lastCumIdx; // last cumulative index
        uint256 fundingGrowthGlobalX128; // per-unit-liquidity funding growth
        uint128 totalLiquidity; // tracked via ModifyLiquidityParams.liquidityDelta
        bool frozen; // set true at/after maturity
    }

    struct Position {
        uint128 liquidity; // last known liquidity for this position
        uint256 fundingGrowthSnapshotX128; // snapshot of global at last update
        // fundingOwedToken1 is token1-denominated funding. +ve: user receives token1, -ve: user owes token1
        int256 fundingOwedToken1;
    }

    // pool state
    mapping(PoolId => PoolMeta) public poolMeta;

    // positions keyed by (owner, ticks, salt, poolId)
    mapping(bytes32 => Position) public positions;

    // Minimal API to observe funding owed

    function fundingOwedToken1(
        address owner,
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        bytes32 salt
    ) external view returns (int256) {
        bytes32 pkey = _positionKey(owner, key.toId(), lower, upper, salt);
        return positions[pkey].fundingOwedToken1;
    }

    // Atomically clear funding owed (router only)
    function clearFundingOwedToken1(
        address owner,
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        bytes32 salt
    ) external returns (int256 amt) {
        require(msg.sender == ROUTER, "NotRouter");
        bytes32 pkey = _positionKey(owner, key.toId(), lower, upper, salt);
        amt = positions[pkey].fundingOwedToken1;
        positions[pkey].fundingOwedToken1 = 0;
        emit FundingOwedCleared(owner, key.toId(), lower, upper, amt);
    }

    constructor(IPoolManager _manager, IETHBaseIndex _base, IRiskEngine _risk, address _factory) {
        MANAGER = _manager;
        BASE_INDEX = _base;
        RISK = _risk;
        FACTORY = _factory;
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.beforeAddLiquidity = true;
        p.afterAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.afterRemoveLiquidity = true;
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
        PoolMeta storage pm = poolMeta[id];
        pm.maturity = maturityTs;
        pm.lastCumIdx = cum;
        pm.lastTs = ts;
        // If maturity is already in the past (or zero passed as sentinel), mark pool frozen immediately
        if (maturityTs == 0 || (maturityTs != 0 && block.timestamp >= maturityTs)) {
            pm.frozen = true;
        }
    }

    function _positionKey(address owner, PoolId id, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        bytes32 idv = PoolId.unwrap(id);
        uint256 tl = uint256(int256(tickLower));
        uint256 tu = uint256(int256(tickUpper));
        bytes32 pkey;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, owner)
            mstore(add(ptr, 0x20), idv)
            mstore(add(ptr, 0x40), tl)
            mstore(add(ptr, 0x60), tu)
            mstore(add(ptr, 0x80), salt)
            pkey := keccak256(ptr, 0xa0)
            mstore(0x40, add(ptr, 0xa0))
        }
        return pkey;
    }

    /// @dev Accrue fundingGrowthGlobalX128 from cumulative index delta / totalLiquidity.
    function _accrue(PoolId id) internal {
        PoolMeta storage pm = poolMeta[id];
        (uint256 cum, uint64 ts) = BASE_INDEX.cumulativeIndex();
        if (ts == pm.lastTs) return; // nothing to do

        if (pm.totalLiquidity > 0) {
            uint256 idxDelta = cum - pm.lastCumIdx;
            int256 growthDelta = int256((idxDelta * FP) / pm.totalLiquidity);
            pm.fundingGrowthGlobalX128 += uint256(growthDelta);
            emit FundingAccrued(id, growthDelta, uint32(ts - pm.lastTs));
        }

        pm.lastCumIdx = cum;
        pm.lastTs = ts;

        // freeze pool if matured
        if (!pm.frozen && pm.maturity != 0 && block.timestamp >= pm.maturity) {
            pm.frozen = true;
        }
    }

    /// @dev Update a position's funding owed to "now" using current global growth and push delta into RiskEngine.
    function _updatePositionOwed(
        address owner,
        PoolId id,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal {
        PoolMeta storage pm = poolMeta[id];
        bytes32 key = _positionKey(owner, id, tickLower, tickUpper, salt);
        Position storage p = positions[key];

        if (p.liquidity == 0) {
            // initialize snapshot for a new position
            p.fundingGrowthSnapshotX128 = pm.fundingGrowthGlobalX128;
            return;
        }

        uint256 growthDelta = pm.fundingGrowthGlobalX128 - p.fundingGrowthSnapshotX128;
        if (growthDelta != 0) {
            // funding owed in token1 = growthDelta * liquidity (in X128)
            int256 delta = int256((growthDelta * p.liquidity) / FP);
            p.fundingOwedToken1 += delta;
            p.fundingGrowthSnapshotX128 = pm.fundingGrowthGlobalX128;

            // Push to RiskEngine with liability sign convention:
            // user credit (delta > 0) reduces liability => send negative to RiskEngine
            RISK.onFundingAccrued(owner, -delta);
        }
    }

    /// @dev Apply a liquidity delta to a position and the pool total, after updating owed.
    function _applyLiquidityDelta(
        address owner,
        PoolId id,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        int256 liquidityDelta
    ) internal {
        PoolMeta storage pm = poolMeta[id];
        bytes32 key = _positionKey(owner, id, tickLower, tickUpper, salt);
        Position storage p = positions[key];

        if (liquidityDelta > 0) {
            uint128 add = uint128(uint256(liquidityDelta));
            p.liquidity += add;
            pm.totalLiquidity += add;
        } else if (liquidityDelta < 0) {
            uint128 sub = uint128(uint256(-liquidityDelta));
            require(p.liquidity >= sub, "liquidity underflow");
            p.liquidity -= sub;
            require(pm.totalLiquidity >= sub, "pool liquidity underflow");
            pm.totalLiquidity -= sub;
        }
        // snapshot after change
        p.fundingGrowthSnapshotX128 = pm.fundingGrowthGlobalX128;
    }

    // ============ User function: collect funding ============

    /// @notice Collect accrued funding for a position and reset owed to zero.
    /// @dev Callable by the position owner (or anyone, paying to owner).
    // Deprecated: external collection should be routed through the Router which
    // calls `clearFundingOwedToken1` and settles transfers. Keep an internal
    // accounting-only helper for internal use/testing.
    function _collectFundingAccounting(
        address owner,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal returns (int256 amount) {
        PoolId id = key.toId();
        _accrue(id);
        _updatePositionOwed(owner, id, tickLower, tickUpper, salt);

        bytes32 pkey = _positionKey(owner, id, tickLower, tickUpper, salt);
        Position storage p = positions[pkey];
        amount = p.fundingOwedToken1;
        p.fundingOwedToken1 = 0;
    }

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        returns (bytes4)
    {
        require(msg.sender == address(MANAGER), "NotManager");
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        require(msg.sender == address(MANAGER), "NotManager");
        require(sender == ROUTER, "UseRouter");
        address trader = abi.decode(hookData, (address));

        PoolId id = key.toId();
        // update funding and frozen flag from index before gating
        _accrue(id);
        require(!poolMeta[id].frozen, "PoolMatured");
        _updatePositionOwed(trader, id, params.tickLower, params.tickUpper, params.salt);

        // baseline IM guard
        RISK.requireIM(trader, block.timestamp);

        // we apply delta in afterAddLiquidity when liquidity is actually adjusted
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        require(msg.sender == address(MANAGER), "NotManager");
        require(sender == ROUTER, "UseRouter");
        address trader = abi.decode(hookData, (address));

        PoolId id = key.toId();
        // apply positive or zero delta
        _applyLiquidityDelta(
            trader, id, params.tickLower, params.tickUpper, params.salt, params.liquidityDelta
        );
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        require(msg.sender == address(MANAGER), "NotManager");
        require(sender == ROUTER, "UseRouter");
        address trader = abi.decode(hookData, (address));

        PoolId id = key.toId();
        _accrue(id);
        _updatePositionOwed(trader, id, params.tickLower, params.tickUpper, params.salt);
        // delta applied in afterRemove
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        require(msg.sender == address(MANAGER), "NotManager");
        require(sender == ROUTER, "UseRouter");
        address trader = abi.decode(hookData, (address));

        PoolId id = key.toId();
        // apply negative or zero delta
        _applyLiquidityDelta(
            trader, id, params.tickLower, params.tickUpper, params.salt, params.liquidityDelta
        );
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(MANAGER), "NotManager");
        require(sender == ROUTER, "UseRouter");
        address trader = abi.decode(hookData, (address));

        PoolId id = key.toId();
        // accrue first to update frozen flag if maturity passed, then gate
        _accrue(id);
        require(!poolMeta[id].frozen, "PoolMatured");

        // margin/risk guard on the real trader
        RISK.requireIM(trader, block.timestamp);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, int128(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
