// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract IRSLiquidityCaps is AccessControl {
    bytes32 public constant RISK_ADMIN = keccak256("RISK_ADMIN");

    mapping(PoolId => uint128) public POOL_CAP;
    mapping(PoolId => uint128) public POOL_USED;

    mapping(address => bool) public ALLOWED_LP;

    event CapSet(PoolId indexed id, uint128 cap);
    event AllowedLP(address indexed lp, bool allowed);
    event Consumed(PoolId indexed id, uint128 amount);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ADMIN, admin);
    }

    function setCap(PoolId id, uint128 cap) external onlyRole(RISK_ADMIN) {
        POOL_CAP[id] = cap;
        emit CapSet(id, cap);
    }

    function setLP(address lp, bool allowed) external onlyRole(RISK_ADMIN) {
        ALLOWED_LP[lp] = allowed;
        emit AllowedLP(lp, allowed);
    }

    function canAdd(address lp, PoolId id, int256 liquidityDelta) external returns (bool) {
        if (!ALLOWED_LP[lp]) return false;
        if (liquidityDelta <= 0) return true;
        uint128 add = uint128(uint256(liquidityDelta));
        uint128 cap = POOL_CAP[id];
        if (cap == 0) return false;
        uint128 used = POOL_USED[id];
        if (used + add > cap) return false;
        POOL_USED[id] = used + add;
        emit Consumed(id, add);
        return true;
    }
}
