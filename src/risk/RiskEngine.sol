// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title RiskEngine
 * @notice Non-custodial margin & risk engine for an IRS-on-Uniswap v4 style system.
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RiskEngine is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant YEAR = 365 days; // 31,536,000
    uint256 public constant ONE = 1e18; // fixed-point 1.0
    uint256 public constant BPS = 10_000; // basis points (100% = 10000)

    // Optional conventional IDs for common collaterals
    uint8 public constant TOKEN1 = 1;
    uint8 public constant WETH = 2;
    uint8 public constant USDC = 3;

    bool public frozen; // if true, all config mutations are disabled
    bool public operatorsFrozen; // optional: lock operator set

    event Frozen();
    event OperatorsFrozen();

    modifier onlyWhenActive() {
        require(!frozen, "frozen");
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function freeze() external onlyOwner onlyWhenActive {
        frozen = true;
        emit Frozen();
    }

    function freezeOperators() external onlyOwner {
        operatorsFrozen = true;
        emit OperatorsFrozen();
    }

    address public priceOracle; // set to owner or a dedicated oracle/adapter
    mapping(address => bool) public operators; // Router/Hook (and tests) that can push deltas

    event OperatorSet(address indexed op, bool allowed);
    event PriceOracleSet(address indexed oracle);

    function setOperator(address op, bool allowed) external onlyOwner {
        require(!operatorsFrozen, "operators frozen");
        operators[op] = allowed;
        emit OperatorSet(op, allowed);
    }

    function setPriceOracle(address oracle) external onlyOwner onlyWhenActive {
        priceOracle = oracle;
        emit PriceOracleSet(oracle);
    }

    modifier onlyOperator() {
        require(operators[msg.sender], "not-operator");
        _;
    }

    struct Collateral {
        uint8 id;
        IERC20 token;
        uint8 decimals;
        uint256 scale; // 10 ** decimals
        uint256 price; // 1e18 (token1 units per 1 token)
        uint256 haircutBps; // 1e4 (e.g. 1000 = 10%)
        bool enabled;
    }

    mapping(uint8 => Collateral) public collaterals;

    event CollateralSet(
        uint8 indexed id,
        address token,
        uint8 decimals,
        uint256 price,
        uint256 haircutBps,
        bool enabled
    );
    event CollateralPrice(uint8 indexed id, uint256 price);
    event CollateralHaircut(uint8 indexed id, uint256 haircutBps);
    event CollateralEnabled(uint8 indexed id, bool enabled);

    function setCollateral(
        uint8 id,
        address token,
        uint8 decimals,
        uint256 price,
        uint256 haircutBps,
        bool enabled
    ) external onlyOwner onlyWhenActive {
        require(token != address(0), "collateral: zero token");
        require(haircutBps < BPS, "haircut too high");
        Collateral storage c = collaterals[id];
        c.id = id;
        c.token = IERC20(token);
        c.decimals = decimals;
        c.scale = 10 ** decimals;
        c.price = price;
        c.haircutBps = haircutBps;
        c.enabled = enabled;
        emit CollateralSet(id, token, decimals, price, haircutBps, enabled);
    }

    function setCollateralPrice(uint8 id, uint256 price) external {
        require(msg.sender == priceOracle, "not-oracle");
        collaterals[id].price = price;
        emit CollateralPrice(id, price);
    }

    function setCollateralHaircut(uint8 id, uint256 haircutBps) external onlyOwner onlyWhenActive {
        require(haircutBps < BPS, "haircut too high");
        collaterals[id].haircutBps = haircutBps;
        emit CollateralHaircut(id, haircutBps);
    }

    function setCollateralEnabled(uint8 id, bool enabled) external onlyOwner onlyWhenActive {
        collaterals[id].enabled = enabled;
        emit CollateralEnabled(id, enabled);
    }

    struct PoolRiskParams {
        uint256 imBps; // initial margin shock in bps
        uint256 mmBps; // maintenance margin shock in bps
        uint256 durationFactor; // 1e18 multiplier for (T - t)/YEAR
        uint256 maxSingleNotional; // notional cap per-position (1e18)
        uint256 maxAccountNotional; // notional cap per-account (1e18)
        bool enabled;
    }

    mapping(bytes32 => PoolRiskParams) public poolRiskParams;

    event PoolRiskConfigured(bytes32 indexed poolId, PoolRiskParams params);

    function setPoolRiskParams(bytes32 poolId, PoolRiskParams calldata p)
        external
        onlyOwner
        onlyWhenActive
    {
        require(p.imBps > 0 && p.mmBps > 0, "bad bps");
        require(p.durationFactor > 0, "bad factor");
        require(p.maxSingleNotional > 0 && p.maxAccountNotional > 0, "bad caps");
        poolRiskParams[poolId] = p;
        emit PoolRiskConfigured(poolId, p);
    }

    struct Position {
        // identity
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt; // allow multiple positions at same ticks
        // economics
        uint256 L; // liquidity-like size (>= 0)
        uint256 kappa; // notional scale (N = L * kappa)
        int256 entryFix; // reserved for PV models (unused here)
        int256 lastPhi; // reserved for PV models (unused here)
        uint256 maturity; // unix ts
    }

    struct Account {
        mapping(uint8 => uint256) collateral; // id => token balance
        int256 fundingDebt; // token1 (positive=liability)
        Position[] positions;
        mapping(bytes32 => uint256) posIndex; // key => idx+1 (0 = absent)
        uint256 notionalSum; // sum of L*kappa
    }

    mapping(address => Account) private accounts;

    event Deposited(address indexed trader, uint8 indexed id, uint256 amount);
    event Withdrawn(address indexed trader, uint8 indexed id, uint256 amount);
    event PositionDelta(
        address indexed trader,
        bytes32 indexed key,
        int256 LDelta,
        uint256 newL,
        uint256 kappa,
        uint256 maturity
    );
    event PositionClosed(address indexed trader, bytes32 indexed key);
    event FundingAccrued(address indexed trader, int256 deltaToken1);

    function positionKey(bytes32 poolId, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, tickLower, tickUpper, salt));
    }

    function _toToken1Value(uint8 id, uint256 amount) internal view returns (uint256) {
        Collateral storage c = collaterals[id];
        if (!c.enabled || amount == 0) return 0;
        // value_1e18 = amount * price / scale * (BPS - haircut)/BPS
        uint256 gross = Math.mulDiv(amount, c.price, c.scale);
        return Math.mulDiv(gross, (BPS - c.haircutBps), BPS);
    }

    function collateralValue(address trader) public view returns (uint256 value1e18) {
        Account storage acct = accounts[trader];
        // Extend as you register more collaterals; 1..3 here for simplicity
        for (uint8 id = 1; id <= 3;) {
            uint256 bal = acct.collateral[id];
            if (bal != 0) value1e18 += _toToken1Value(id, bal);
            unchecked {
                ++id;
            }
        }
    }

    function _equity(address trader) internal view returns (int256 eq) {
        eq = int256(collateralValue(trader)) - accounts[trader].fundingDebt;
    }

    function equity(address trader) external view returns (int256) {
        return _equity(trader);
    }

    function deposit(uint8 id, uint256 amount) external nonReentrant {
        Collateral storage c = collaterals[id];
        require(c.enabled, "collateral disabled");
        require(amount > 0, "amount=0");
        c.token.safeTransferFrom(msg.sender, address(this), amount);
        accounts[msg.sender].collateral[id] += amount;
        emit Deposited(msg.sender, id, amount);
    }

    /// @notice Withdraw only if post-withdraw equity >= IM (no under-margin withdrawals).
    function withdraw(uint8 id, uint256 amount) external nonReentrant {
        Account storage acct = accounts[msg.sender];
        require(acct.collateral[id] >= amount, "insufficient collateral");

        // Pro-forma: equity after withdrawal must satisfy IM
        uint256 nowTs = block.timestamp;
        int256 eqBefore = _equity(msg.sender);
        uint256 val1e18 = _toToken1Value(id, amount);
        int256 eqAfter = eqBefore - int256(val1e18);
        uint256 im = imRequirement(msg.sender, nowTs);
        require(eqAfter >= int256(im), "withdraw: IM breach");

        acct.collateral[id] -= amount;
        collaterals[id].token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, id, amount);
    }

    /// @notice Called by Router/Hook when a position's liquidity changes (add/remove).
    function onPositionDelta(
        address trader,
        bytes32 poolId,
        int24 tickL,
        int24 tickU,
        bytes32 salt,
        uint256 kappa,
        uint256 maturity,
        int256 LDelta
    ) external onlyOperator {
        PoolRiskParams storage pr = poolRiskParams[poolId];
        require(pr.enabled, "pool not enabled");
        require(maturity > block.timestamp, "pool matured");

        Account storage acct = accounts[trader];
        bytes32 key = positionKey(poolId, tickL, tickU, salt);
        uint256 idx = acct.posIndex[key];

        if (idx == 0) {
            require(LDelta > 0, "no existing pos");
            Position memory p = Position({
                poolId: poolId,
                tickLower: tickL,
                tickUpper: tickU,
                salt: salt,
                L: uint256(LDelta),
                kappa: kappa,
                entryFix: 0,
                lastPhi: 0,
                maturity: maturity
            });
            acct.positions.push(p);
            acct.posIndex[key] = acct.positions.length; // idx = len
            uint256 addNotional = p.L * p.kappa;
            acct.notionalSum += addNotional;
            _enforceCaps(trader, p.poolId, addNotional, pr);
            requireIM(trader, block.timestamp);
            emit PositionDelta(trader, key, LDelta, p.L, kappa, maturity);
            return;
        }

        Position storage pos = acct.positions[idx - 1];
        require(pos.poolId == poolId, "pool mismatch");

        if (LDelta == 0) {
            emit PositionDelta(trader, key, 0, pos.L, pos.kappa, pos.maturity);
            return;
        }

        if (LDelta > 0) {
            uint256 u = uint256(LDelta);
            pos.L += u;
            if (pos.kappa == 0) pos.kappa = kappa;
            if (pos.maturity == 0) pos.maturity = maturity;
            uint256 addNotional = u * (pos.kappa == 0 ? kappa : pos.kappa);
            acct.notionalSum += addNotional;
            _enforceCaps(trader, pos.poolId, addNotional, pr);
            requireIM(trader, block.timestamp);
        } else {
            uint256 d = uint256(-LDelta);
            require(pos.L >= d, "burn exceeds L");
            pos.L -= d;
            uint256 subNotional = d * (pos.kappa == 0 ? kappa : pos.kappa);
            acct.notionalSum =
                (acct.notionalSum >= subNotional) ? (acct.notionalSum - subNotional) : 0;

            if (pos.L == 0) {
                _removePosition(acct, key, idx - 1);
                emit PositionClosed(trader, key);
                emit PositionDelta(trader, key, LDelta, 0, pos.kappa, pos.maturity);
                return;
            }
        }

        emit PositionDelta(trader, key, LDelta, pos.L, pos.kappa, pos.maturity);
    }

    function _removePosition(Account storage acct, bytes32 key, uint256 i) internal {
        uint256 last = acct.positions.length - 1;
        if (i != last) {
            Position memory moved = acct.positions[last];
            acct.positions[i] = moved;
            bytes32 movedKey =
                positionKey(moved.poolId, moved.tickLower, moved.tickUpper, moved.salt);
            acct.posIndex[movedKey] = i + 1;
        }
        acct.positions.pop();
        acct.posIndex[key] = 0;
    }

    /// @notice Integration calls whenever funding (token1) accrues for the trader.
    /// @param deltaToken1 Positive => liability increased (owes more). Negative => liability decreased (credit).
    function onFundingAccrued(address trader, int256 deltaToken1) external onlyOperator {
        accounts[trader].fundingDebt += deltaToken1;
        emit FundingAccrued(trader, deltaToken1);
    }

    // ---------------------------------------------------------------------
    // Margin math (DV01-based)
    // ---------------------------------------------------------------------
    function dv01(Position memory pos, uint256 nowTs, uint256 durationFactor)
        public
        pure
        returns (uint256)
    {
        if (nowTs >= pos.maturity) return 0;
        uint256 duration = pos.maturity - nowTs;
        uint256 N = pos.L * pos.kappa; // notional (1e18)
        uint256 timeScaled = Math.mulDiv(N, duration, YEAR);
        return Math.mulDiv(timeScaled, durationFactor, ONE);
    }

    function imRequirement(address trader, uint256 nowTs) public view returns (uint256 im) {
        Account storage acct = accounts[trader];
        uint256 len = acct.positions.length;
        for (uint256 i = 0; i < len;) {
            Position storage p = acct.positions[i];
            PoolRiskParams storage pr = poolRiskParams[p.poolId];
            if (pr.enabled) {
                uint256 dv = dv01(p, nowTs, pr.durationFactor);
                im += Math.mulDiv(dv, pr.imBps, BPS);
            }
            unchecked {
                ++i;
            }
        }
    }

    function mmRequirement(address trader, uint256 nowTs) public view returns (uint256 mm) {
        Account storage acct = accounts[trader];
        uint256 len = acct.positions.length;
        for (uint256 i = 0; i < len;) {
            Position storage p = acct.positions[i];
            PoolRiskParams storage pr = poolRiskParams[p.poolId];
            if (pr.enabled) {
                uint256 dv = dv01(p, nowTs, pr.durationFactor);
                mm += Math.mulDiv(dv, pr.mmBps, BPS);
            }
            unchecked {
                ++i;
            }
        }
    }

    function healthFactor(address trader, uint256 nowTs)
        public
        view
        returns (uint256 hf, int256 eq, uint256 im, uint256 mm)
    {
        eq = _equity(trader);
        im = imRequirement(trader, nowTs);
        mm = mmRequirement(trader, nowTs);
        if (mm == 0) {
            hf = type(uint256).max;
        } else {
            hf = (eq <= 0) ? 0 : Math.mulDiv(uint256(eq), ONE, mm);
        }
    }

    function requireIM(address trader, uint256 nowTs) public view {
        int256 eq = _equity(trader);
        uint256 im = imRequirement(trader, nowTs);
        require(eq >= int256(im), "margin: insufficient equity");
    }

    function _enforceCaps(
        address trader,
        bytes32 poolId,
        uint256 notionalAdded,
        PoolRiskParams storage pr
    ) internal view {
        require(pr.enabled, "pool disabled");
        // Per-position cap should be enforced by the integration on creation.
        uint256 newSum = accounts[trader].notionalSum + notionalAdded;
        require(newSum <= pr.maxAccountNotional, "account notional cap");
    }

    struct Health {
        uint256 hf; // 1e18 (HF >= 1e18 is healthy)
        int256 equity; // 1e18 token1 units
        uint256 im; // 1e18
        uint256 mm; // 1e18
        int256 funding; // 1e18 (liability if positive)
    }

    function previewHealth(address trader, uint256 nowTs) external view returns (Health memory h) {
        (h.hf, h.equity, h.im, h.mm) = healthFactor(trader, nowTs);
        h.funding = accounts[trader].fundingDebt;
    }

    function previewAfterPositionDelta(
        address trader,
        bytes32 poolId,
        uint256 kappa,
        uint256 maturity,
        int256 LDelta,
        uint256 nowTs
    ) external view returns (Health memory h) {
        (h.hf, h.equity, h.im, h.mm) = healthFactor(trader, nowTs);
        PoolRiskParams storage pr = poolRiskParams[poolId];
        if (!pr.enabled || LDelta == 0) return h;

        uint256 dv;
        if (LDelta > 0) {
            uint256 Nadd = uint256(LDelta) * kappa;
            uint256 timeScaled =
                Math.mulDiv(Nadd, (maturity > nowTs ? (maturity - nowTs) : 0), YEAR);
            dv = Math.mulDiv(timeScaled, pr.durationFactor, ONE);
            h.im += Math.mulDiv(dv, pr.imBps, BPS);
            h.mm += Math.mulDiv(dv, pr.mmBps, BPS);
        } else {
            uint256 Nsub = uint256(-LDelta) * kappa;
            uint256 timeScaled =
                Math.mulDiv(Nsub, (maturity > nowTs ? (maturity - nowTs) : 0), YEAR);
            dv = Math.mulDiv(timeScaled, pr.durationFactor, ONE);
            uint256 dim = Math.mulDiv(dv, pr.imBps, BPS);
            uint256 dmm = Math.mulDiv(dv, pr.mmBps, BPS);
            h.im = h.im > dim ? (h.im - dim) : 0;
            h.mm = h.mm > dmm ? (h.mm - dmm) : 0;
        }
        h.hf = h.mm == 0
            ? type(uint256).max
            : (h.equity <= 0 ? 0 : Math.mulDiv(uint256(h.equity), ONE, h.mm));
    }

    function previewAfterSwapNotional(
        address trader,
        bytes32 poolId,
        uint256 absNotional,
        uint256 maturity,
        uint256 nowTs
    ) external view returns (Health memory h) {
        (h.hf, h.equity, h.im, h.mm) = healthFactor(trader, nowTs);
        PoolRiskParams storage pr = poolRiskParams[poolId];
        if (!pr.enabled || absNotional == 0) return h;

        uint256 timeScaled =
            Math.mulDiv(absNotional, (maturity > nowTs ? (maturity - nowTs) : 0), YEAR);
        uint256 dv = Math.mulDiv(timeScaled, pr.durationFactor, ONE);
        h.im += Math.mulDiv(dv, pr.imBps, BPS);
        h.mm += Math.mulDiv(dv, pr.mmBps, BPS);
        h.hf = h.mm == 0
            ? type(uint256).max
            : (h.equity <= 0 ? 0 : Math.mulDiv(uint256(h.equity), ONE, h.mm));
    }

    uint256 public liquidationPenaltyBps = 600; // 6% trader penalty -> seized as bonus
    uint256 public closeFactorMinBps = 5000; // 50% when just under MM
    uint256 public closeFactorMaxBps = 10000; // 100% when critically under MM
    uint256 public hfCritical = 9e17; // HF <= 0.90 -> allow full close

    // Optional insurance sink: share (on the penalty portion) to protocol fund
    address public insurance;
    uint256 public liqFeeShareBps; // share of penalty to insurance (0..10000)

    event LiquidationParamsSet(
        uint256 penaltyBps, uint256 closeMinBps, uint256 closeMaxBps, uint256 hfCritical
    );
    event InsuranceSet(address indexed insurance, uint256 feeShareBps);
    event SeizedCollateral(
        address indexed trader, uint8 indexed id, uint256 amount, uint256 value1e18
    );
    event Liquidated(
        address indexed trader,
        address indexed liquidator,
        uint256 repaidToken1,
        uint256 seizedValue1e18,
        uint256 insuranceValue1e18
    );
    event BadDebt(address indexed trader, uint256 shortfallToken1);

    function setLiquidationParams(
        uint256 penaltyBps,
        uint256 closeMinBps,
        uint256 closeMaxBps,
        uint256 _hfCritical
    ) external onlyOwner onlyWhenActive {
        require(penaltyBps <= 2000, "penalty too high"); // <=20%
        require(closeMinBps > 0 && closeMinBps <= BPS, "min bps");
        require(closeMaxBps >= closeMinBps && closeMaxBps <= BPS, "max bps");
        require(_hfCritical < ONE, "hfCritical<1");
        liquidationPenaltyBps = penaltyBps;
        closeFactorMinBps = closeMinBps;
        closeFactorMaxBps = closeMaxBps;
        hfCritical = _hfCritical;
        emit LiquidationParamsSet(penaltyBps, closeMinBps, closeMaxBps, _hfCritical);
    }

    function setInsurance(address _insurance, uint256 feeShareBps_)
        external
        onlyOwner
        onlyWhenActive
    {
        require(feeShareBps_ <= BPS, "fee share > 100%");
        insurance = _insurance;
        liqFeeShareBps = feeShareBps_;
        emit InsuranceSet(_insurance, feeShareBps_);
    }

    function _ceilMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        uint256 z = Math.mulDiv(x, y, d);
        if (Math.mulDiv(z, d, y) < x) z += 1; // round up if truncated
        return z;
    }

    function _computeCloseFactorBps(uint256 hf) internal view returns (uint256 bps) {
        if (hf <= hfCritical) return closeFactorMaxBps;
        if (hf >= ONE) return 0;
        unchecked {
            uint256 range = ONE - hfCritical;
            uint256 prog = ((ONE - hf) * BPS) / range; // 0..BPS as hf→1.0
            uint256 added = ((closeFactorMaxBps - closeFactorMinBps) * prog) / BPS;
            return closeFactorMinBps + added;
        }
    }

    function _sumSeizeableValue(address trader, uint8[] memory seizeOrder)
        internal
        view
        returns (uint256 v)
    {
        Account storage acct = accounts[trader];
        for (uint256 i = 0; i < seizeOrder.length; ++i) {
            uint8 id = seizeOrder[i];
            uint256 bal = acct.collateral[id];
            if (bal == 0) continue;
            v += _toToken1Value(id, bal); // haircuts applied
        }
    }

    function _seizeTo(
        address trader,
        address recipient,
        uint256 value1e18,
        uint8[] memory seizeOrder
    ) internal {
        if (value1e18 == 0) return;
        Account storage acct = accounts[trader];
        uint256 remaining = value1e18;

        for (uint256 i = 0; i < seizeOrder.length && remaining > 0; ++i) {
            uint8 id = seizeOrder[i];
            Collateral storage c = collaterals[id];
            if (!c.enabled) continue;

            uint256 avail = acct.collateral[id];
            if (avail == 0) continue;

            // denom (token1 per 1 token, 1e18) with haircut
            uint256 denom = Math.mulDiv(c.price, (BPS - c.haircutBps), BPS);
            if (denom == 0) continue;

            // tokensNeeded = ceil(remaining * scale / denom)
            uint256 needed = _ceilMulDiv(remaining, c.scale, denom);
            uint256 seizeAmt = needed > avail ? avail : needed;
            if (seizeAmt == 0) continue;

            uint256 seizedVal = _toToken1Value(id, seizeAmt);
            if (seizedVal > remaining) seizedVal = remaining;

            acct.collateral[id] = avail - seizeAmt;
            c.token.safeTransfer(recipient, seizeAmt);

            emit SeizedCollateral(trader, id, seizeAmt, seizedVal);
            remaining -= seizedVal;
        }

        require(remaining == 0, "insufficient collateral to seize");
    }

    /// @notice Preview liquidation caps and outputs.
    function previewLiquidation(address trader, uint256 repayDesired, uint8[] calldata seizeOrder)
        external
        view
        returns (uint256 repayCap, uint256 seizeValue1e18, uint256 debtBefore, uint256 hf)
    {
        uint256 mm;
        (hf,,, mm) = healthFactor(trader, block.timestamp);
        require(hf < ONE || mm > 0, "not liquidatable");

        int256 debtSigned = accounts[trader].fundingDebt;
        uint256 debt = debtSigned > 0 ? uint256(debtSigned) : 0;

        uint256 cf = _computeCloseFactorBps(hf);
        uint256 byCloseFactor = Math.mulDiv(debt, cf, BPS);

        uint256 seizeable = _sumSeizeableValue(trader, seizeOrder);
        uint256 byCollateral = Math.mulDiv(seizeable, BPS, BPS + liquidationPenaltyBps);

        uint256 cap = debt;
        if (byCloseFactor < cap) cap = byCloseFactor;
        if (byCollateral < cap) cap = byCollateral;
        if (repayDesired < cap) cap = repayDesired;

        repayCap = cap;
        seizeValue1e18 = Math.mulDiv(repayCap, (BPS + liquidationPenaltyBps), BPS);
        debtBefore = debt;
    }

    /// @notice Permissionless liquidation. Repay trader's token1 debt and seize multi-collateral.
    /// @param trader      The under-margined account.
    /// @param repayDesired Liquidator's desired token1 repay amount (will be capped).
    /// @param recipient   Recipient of seized collateral (usually msg.sender).
    /// @param seizeOrder  Ordered collateral ids to seize from (e.g., [1,2,3] = TOKEN1,WETH,USDC).
    function liquidate(
        address trader,
        uint256 repayDesired,
        address recipient,
        uint8[] calldata seizeOrder
    ) external nonReentrant {
        require(recipient != address(0), "bad recipient");
        require(repayDesired > 0, "repay=0");

        (uint256 hf,,, uint256 mm) = healthFactor(trader, block.timestamp);
        require(hf < ONE || mm > 0, "not liquidatable");

        Account storage acct = accounts[trader];
        int256 debtSigned = acct.fundingDebt;
        require(debtSigned > 0, "no debt");
        uint256 debt = uint256(debtSigned);

        uint256 cf = _computeCloseFactorBps(hf);
        uint256 byCloseFactor = Math.mulDiv(debt, cf, BPS);
        uint256 seizeable = _sumSeizeableValue(trader, seizeOrder);
        uint256 byCollateral = Math.mulDiv(seizeable, BPS, (BPS + liquidationPenaltyBps));

        uint256 repay = repayDesired;
        if (repay > debt) repay = debt;
        if (repay > byCloseFactor) repay = byCloseFactor;
        if (repay > byCollateral) repay = byCollateral;
        require(repay > 0, "repay too small");

        // Pull TOKEN1 from liquidator
        Collateral storage c1 = collaterals[TOKEN1];
        require(c1.enabled, "token1 disabled");
        c1.token.safeTransferFrom(msg.sender, address(this), repay);

        // Reduce debt
        acct.fundingDebt = int256(debt - repay);

        // Total value to seize (token1 units): repay + penalty
        uint256 totalSeize = Math.mulDiv(repay, (BPS + liquidationPenaltyBps), BPS);

        // Insurance fee slice only on penalty portion
        uint256 penaltyVal = totalSeize - repay;
        uint256 insuranceVal = (insurance != address(0) && liqFeeShareBps != 0)
            ? Math.mulDiv(penaltyVal, liqFeeShareBps, BPS)
            : 0;

        // Seize to insurance first (if any), then the remainder to the liquidator
        if (insuranceVal > 0) {
            _seizeTo(trader, insurance, insuranceVal, seizeOrder);
        }
        _seizeTo(trader, recipient, totalSeize - insuranceVal, seizeOrder);

        emit Liquidated(trader, msg.sender, repay, totalSeize, insuranceVal);

        // If still underwater and no collateral left, signal bad debt (for offchain/insurance handling).
        if (acct.fundingDebt > 0) {
            uint256 residual;
            for (uint8 id = 1; id <= 3;) {
                residual += acct.collateral[id];
                unchecked {
                    ++id;
                }
            }
            if (residual == 0) emit BadDebt(trader, uint256(acct.fundingDebt));
        }
    }

    function collateralBalance(address trader, uint8 id) external view returns (uint256) {
        return accounts[trader].collateral[id];
    }

    function fundingDebt(address trader) external view returns (int256) {
        return accounts[trader].fundingDebt;
    }

    function positionsLength(address trader) external view returns (uint256) {
        return accounts[trader].positions.length;
    }

    function getPosition(address trader, uint256 index) external view returns (Position memory) {
        return accounts[trader].positions[index];
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
